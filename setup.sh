#!/bin/bash

# Unofficial Bash Strict Mode
set -euo pipefail
IFS=$'\n\t'

finish() {
  local ret=$?
  if [ ${ret} -ne 0 ] && [ ${ret} -ne 130 ]; then
    echo
    echo "ERROR: Failed to setup XFCE on Termux."
    echo "Please refer to the error message(s) above"
  fi
}

trap finish EXIT

clear

echo ""
echo "This script will install XFCE Desktop in Termux along with a Debian proot"
echo ""
read -r -p "Please enter username for proot installation: " username </dev/tty

termux-setup-storage
termux-change-repo

pkg update -y -o Dpkg::Options::="--force-confold"
pkg upgrade -y -o Dpkg::Options::="--force-confold"
#pkg uninstall dbus -y
pkg install wget ncurses-utils dbus proot-distro x11-repo tur-repo pulseaudio -y

#Create default directories
mkdir -p Desktop
mkdir -p Downloads

setup_proot() {
#Install Debian proot
proot-distro install debian
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 apt update
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 apt upgrade -y
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 apt install sudo wget libvulkan1 glmark2 xfce4 xfce4-goodies pavucontrol-qt -y

#Install DRI3 patched driver
wget https://github.com/jane00/Termux_XFCE/raw/main/mesa-vulkan-kgsl_23.3.0-ubuntu_arm64.deb
mv mesa-vulkan-kgsl_23.3.0-ubuntu_arm64.deb $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/root/
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 dpkg -i mesa-vulkan-kgsl_23.3.0-ubuntu_arm64.deb
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 rm mesa-vulkan-kgsl_23.3.0-ubuntu_arm64.deb

#Create user
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 groupadd storage
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 groupadd wheel
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 useradd -m -g users -G wheel,audio,video,storage -s /bin/bash "$username"

#Add user to sudoers
chmod u+rw $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/etc/sudoers
echo "$username ALL=(ALL) NOPASSWD:ALL" | tee -a $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/etc/sudoers > /dev/null
chmod u-w  $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/etc/sudoers

#Set proot DISPLAY
echo "export DISPLAY=:1.0" >> $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/home/$username/.bashrc

#Set proot timezone
timezone=$(getprop persist.sys.timezone)
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 rm /etc/localtime
proot-distro login debian --shared-tmp -- env DISPLAY=:1.0 cp /usr/share/zoneinfo/$timezone /etc/localtime
}

setup_xfce() {
#Install xfce4 desktop and additional packages
pkg install git neofetch mesa-zink virglrenderer-mesa-zink vulkan-loader-android glmark2 xfce4 xfce4-goodies pavucontrol-qt -y

#Create .bashrc
#cp $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/etc/skel/.bashrc $HOME/.bashrc

#Enable Sound
echo "
pulseaudio --start --exit-idle-time=-1
pacmd load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1
" > $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/home/$username/.sound

echo "
source .sound" >> $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/home/$username/.bashrc

}

setup_termux_x11() {
# Install Termux-X11
sed -i '12s/^#//' $HOME/.termux/termux.properties

wget https://github.com/jane00/Termux_XFCE/raw/main/termux-x11.deb
dpkg -i termux-x11.deb
rm termux-x11.deb
#apt-mark hold termux-x11-nightly

wget https://github.com/jane00/Termux_XFCE/raw/main/termux-x11.apk
mv termux-x11.apk $HOME/storage/downloads/
termux-open $HOME/storage/downloads/termux-x11.apk

#Create kill_termux_x11.desktop
echo "[Desktop Entry]
Version=1.0
Type=Application
Name=Kill Termux X11
Comment=
Exec=kill_termux_x11
Icon=system-shutdown
Categories=System;
Path=
StartupNotify=false
" > $HOME/Desktop/kill_termux_x11.desktop
chmod +x $HOME/Desktop/kill_termux_x11.desktop
mv $HOME/Desktop/kill_termux_x11.desktop $HOME/../usr/share/applications

#Create XFCE Start and Shutdown
cat <<'EOF' > start
#!/bin/bash

varname=$(basename $HOME/../usr/var/lib/proot-distro/installed-rootfs/debian/home/*)

if [[ $1 != "dri3" ]]
then
  MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy virgl_test_server --use-egl-surfaceless &
fi

sleep 1
XDG_RUNTIME_DIR=${TMPDIR} termux-x11 :1.0 &
sleep 1
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity > /dev/null 2>&1
sleep 1

if [[ $1 != "dri3" ]]
then
  env DISPLAY=:1.0 GALLIUM_DRIVER=zink dbus-launch --exit-with-session xfce4-session & > /dev/null 2>&1
else
  proot-distro login debian --user $varname --shared-tmp -- env DISPLAY=:1.0 MESA_LOADER_DRIVER_OVERRIDE=zink TU_DEBUG=noconform dbus-launch --exit-with-session xfce4-session & > /dev/null 2>&1
fi

sleep 5
process_id=$(ps -aux | grep '[x]fce4-screensaver' | awk '{print $2}')
kill "$process_id" > /dev/null 2>&1

EOF

chmod +x start
mv start $HOME/../usr/bin

#Shutdown Utility
cat <<'EOF' > $HOME/../usr/bin/kill_termux_x11
#!/bin/bash

# Check if Apt, dpkg, or Nala is running in Termux or Proot
if pgrep -f 'apt|apt-get|dpkg|nala'; then
  zenity --info --text="Software is currently installing in Termux or Proot. Please wait for this processes to finish before continuing."
  exit 1
fi

# Get the process IDs of Termux-X11 and XFCE sessions
termux_x11_pid=$(pgrep -f "/system/bin/app_process / com.termux.x11.Loader :1.0")
xfce_pid=$(pgrep -f "xfce4-session")

# Check if the process IDs exist
if [ -n "$termux_x11_pid" ] && [ -n "$xfce_pid" ]; then
  # Kill the processes
  kill -9 "$termux_x11_pid" "$xfce_pid"
  zenity --info --text="Termux-X11 and XFCE sessions closed."
else
  zenity --info --text="Termux-X11 or XFCE session not found."
fi

info_output=$(termux-info)
pid=$(echo "$info_output" | grep -o 'TERMUX_APP_PID=[0-9]\+' | awk -F= '{print $2}')
kill "$pid"

exit 0

EOF

chmod +x $HOME/../usr/bin/kill_termux_x11
}

setup_proot
setup_xfce
setup_termux_x11

rm setup.sh
#source .bashrc
#termux-reload-settings

########
##Finish ##
########

clear -x
echo ""
echo ""
echo "Setup completed successfully!"
echo ""
echo "You can now connect to your Termux XFCE4 Desktop to open the desktop use the command start"
echo ""
echo "This will start the termux-x11 server in termux and start the XFCE Desktop and then open the installed Termux-X11 app."
echo ""
echo "To exit, double click the Kill Termux X11 icon on the desktop."
echo ""
echo "Enjoy your Termux XFCE4 Desktop experience!"
echo ""
echo ""
