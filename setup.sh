#!/bin/bash

sudo apt install wget tar git build-essential gcc-aarch64-linux-gnu flex bison libssl-dev

function cleanup() {
	kill -9 $SUDO_PID
	exit 0
}

function sudo_refresh_loop() {
	while true; do
		sudo -v
		sleep 60
	done
}

function download_with_retry() {
	local url=$1
	local retries=3
	local count=0
	local success=0

	while [ $count -lt $retries ]; do
		wget $url
		if [ $? -eq 0 ]; then
			success=1
			break
		else
			echo "Download failed. Retrying... ($((count+1))/$retries)"
			count=$((count+1))
			sleep 5
		fi
	done

	if [ $success -eq 0 ]; then
		echo "Failed to download $url after $retries attempts."
		exit 1
	fi
}

trap cleanup SIGINT SIGTERM

# keep sudo credentials alive in the background
sudo -v
sudo_refresh_loop &
SUDO_PID=$!
START_TIME=$(date +%s)

# Add to bashrc if necessary
BASHRC="$HOME/.bashrc"
exists=$(cat $BASHRC | grep "ARK_JETSON_KERNEL_DIR")
if [ -z "$exists" ]; then
	echo "export ARK_JETSON_KERNEL_DIR=$PWD" >> $BASHRC
	export ARK_JETSON_KERNEL_DIR=$PWD
fi

BSP_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/release/jetson_linux_r36.3.0_aarch64.tbz2"
ROOT_FS_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/release/tegra_linux_sample-root-filesystem_r36.3.0_aarch64.tbz2"
export L4T_RELEASE_PACKAGE=$(basename $BSP_URL)
export SAMPLE_FS_PACKAGE=$(basename $ROOT_FS_URL)
export BOARD="jetson-orin-nano-devkit"

# remove previous
sudo rm -rf source_build
sudo rm -rf prebuilt

pushd .
mkdir -p prebuilt
cd prebuilt

# https://developer.nvidia.com/embedded/jetson-linux-archive
echo "Downloading prebuilt BSP and root filesystem"
download_with_retry $BSP_URL
download_with_retry $ROOT_FS_URL

# https://docs.nvidia.com/jetson/archives/r36.3/DeveloperGuide/IN/QuickStart.html#to-flash-the-jetson-developer-kit-operating-software
echo "Untarring files, this may take some time"
tar xf $L4T_RELEASE_PACKAGE
sudo tar xpf $SAMPLE_FS_PACKAGE -C Linux_for_Tegra/rootfs/

echo "Satisfying prerequisites"
sudo Linux_for_Tegra/tools/l4t_flash_prerequisites.sh
echo "Applying binaries"
sudo Linux_for_Tegra/apply_binaries.sh --debug

# Apply ARK compile device tree
rm -rf ark_jetson_compiled_device_tree_files
git clone -b ark_36.3.0.2 https://github.com/ARK-Electronics/ark_jetson_compiled_device_tree_files.git
echo "Copying device tree files"
sudo cp -r ark_jetson_compiled_device_tree_files/Linux_for_Tegra/* Linux_for_Tegra/

echo "Setting up login credentials for the Jetson"
sudo -E $ARK_JETSON_KERNEL_DIR/configure_user.sh

popd

##### Setup source build
pushd .
mkdir -p source_build
cd source_build

echo "Downloading Jetson sources"
download_with_retry https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/sources/public_sources.tbz2
echo "Extracting Jetson sources"
tar -xjf public_sources.tbz2
pushd .
cd Linux_for_Tegra/source
echo "Extracting kernel source"
tar xf kernel_src.tbz2
tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2

# Edit the defconfig file
echo "Editing kernel defconfig"
# Add the following to the end of the file
echo "CONFIG_USB_WDM=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_USB_NET_DRIVERS=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_USB_NET_QMI_WWAN=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_USB_SERIAL_QUALCOMM=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_WLAN=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_WLAN_VENDOR_INTEL=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_IWLWIFI=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_IWLWIFI_LEDS=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_IWLDVM=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_IWLMVM=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_IWLWIFI_OPMODE_MODULAR=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_ATH_COMMON=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_WLAN_VENDOR_ATH=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_NET_VENDOR_ATHEROS=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_ATH10K_CE=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_ATH10K_USB=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_CRYPTO_MICHAEL_MIC=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_ATH11K=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig
echo "CONFIG_ATH11K_PCI=y" >> kernel/kernel-jammy-src/arch/arm64/configs/defconfig

popd

pushd .
mkdir -p $HOME/l4t-gcc
cd $HOME/l4t-gcc
TOOLCHAIN_TAR="aarch64--glibc--stable-2022.08-1.tar.bz2"
EXTRACTED_DIR="aarch64--glibc--stable-2022.08-1"

if [ ! -f "$TOOLCHAIN_TAR" ]; then
	echo "Downloading Jetson bootlin toolchain"
	download_with_retry https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/$TOOLCHAIN_TAR
else
	echo "Jetson bootlin toolchain archive already exists, skipping download"
fi

if [ ! -d "$EXTRACTED_DIR" ]; then
	echo "Extracting Jetson bootlin toolchain"
	tar xf $TOOLCHAIN_TAR
else
	echo "Jetson bootlin toolchain already extracted, skipping extraction"
fi
popd

# Clone ARK device tree
echo "Downloading ARK device tree"
rm -rf ark_jetson_orin_nano_nx_device_tree
git clone -b ark_36.3.0.1 https://github.com/ARK-Electronics/ark_jetson_orin_nano_nx_device_tree.git
echo "Copying ARK device tree files"
cp -r ark_jetson_orin_nano_nx_device_tree/* Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/
popd

END_TIME=$(date +%s)
TOTAL_TIME=$((${END_TIME}-${START_TIME}))
echo "Finished -- $(date -d@${TOTAL_TIME} -u +%H:%M:%S)"
echo "You can now flash the device"

cleanup
