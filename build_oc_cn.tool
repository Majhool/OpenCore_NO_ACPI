#!/bin/bash

abort() {
  echo "ERROR: $1!"
  exit 1
}

buildutil() {
  UTILS=(
    "AppleEfiSignTool"
    "ACPIe"
    "EfiResTool"
    "ext4read"
    "LogoutHook"
    "acdtinfo"
    "disklabel"
    "icnspack"
    "macserial"
    "ocpasswordgen"
    "ocvalidate"
    "TestBmf"
    "TestCpuFrequency"
    "TestDiskImage"
    "TestHelloWorld"
    "TestImg4"
    "TestKextInject"
    "TestMacho"
    "TestMp3"
    "TestExt4Dxe"
    "TestFatDxe"
    "TestNtfsDxe"
    "TestPeCoff"
    "TestProcessKernel"
    "TestRsaPreprocess"
    "TestSmbios"
  )

  if [ "$HAS_OPENSSL_BUILD" = "1" ]; then
    UTILS+=("RsaTool")
  fi

  local cores
  cores=$(getconf _NPROCESSORS_ONLN)

  pushd "${selfdir}/Utilities" || exit 1
  for util in "${UTILS[@]}"; do
    cd "$util" || exit 1
    make clean &>/dev/null || exit 1
    make -j "$cores" &>/dev/null || exit 1
    #
    # FIXME: Do not build RsaTool for Win32 without OpenSSL.
    #
    if [ "$util" = "RsaTool" ] && [ "$HAS_OPENSSL_W32BUILD" != "1" ]; then
      continue
    fi

    if [ "$(which i686-w64-mingw32-gcc)" != "" ]; then
      UDK_ARCH=Ia32 CC=i686-w64-mingw32-gcc STRIP=i686-w64-mingw32-strip DIST=Windows make clean &>/dev/null || exit 1
      UDK_ARCH=Ia32 CC=i686-w64-mingw32-gcc STRIP=i686-w64-mingw32-strip DIST=Windows make -j "$cores" &>/dev/null || exit 1
    fi
    if [ "$(which x86_64-linux-musl-gcc)" != "" ]; then
      STATIC=1 SUFFIX=.linux UDK_ARCH=X64 CC=x86_64-linux-musl-gcc STRIP=x86_64-linux-musl-strip DIST=Linux make clean &>/dev/null || exit 1
      STATIC=1 SUFFIX=.linux UDK_ARCH=X64 CC=x86_64-linux-musl-gcc STRIP=x86_64-linux-musl-strip DIST=Linux make -j "$cores" &>/dev/null || exit 1
    fi
    cd - || exit 1
  done
  popd || exit
}

get_inf_version() {
  VER="VERSION_STRING"

  if [ ! -f "${1}" ]; then
    echo "缺少 .inf 文件 ${1}" > /dev/stderr
    exit 1
  fi

  ver_line=$(grep -E "${VER} *=" "${1}")

  if [ "${ver_line}" = "" ] ; then
    echo "在 ${1} 里缺少 ${VER}" > /dev/stderr
    exit 1
  fi

  read -ra ver_array <<<"${ver_line}"

  if [ "${ver_array[0]}" != "${VER}" ] ||
     [ "${ver_array[1]}" != "=" ] ||
     [ "${ver_array[2]}" = "" ] ; then
    echo "${1}中${VER}行格式错误" > /dev/stderr
    exit 1
  fi

  echo "${ver_array[2]}"
}

package() {
  if [ ! -d "$1" ]; then
    echo "丢失包目录$1"
    exit 1
  fi

  local ver
  ver=$(grep OPEN_CORE_VERSION ./Include/Acidanthera/Library/OcMainLib.h | sed 's/.*"\(.*\)".*/\1/' | grep -E '^[0-9.]+$')
  if [ "$ver" = "" ]; then
    echo "无效版本 $ver"
    ver="UNKNOWN"
  fi

  selfdir=$(pwd)
  pushd "$1" &>/dev/null || exit 1
  rm -rf tmp || exit 1

  # 显示打包进度
  show_package_progress() {
    local step=$1
    local total=$2
    local current=$3
    local dots=""
    local arr=("|" "/" "-" "\\")
    local index=$((current % 4))

    for ((i=0; i<current; i++)); do
      dots="$dots."
    done

    # 使用 stderr 输出进度，避免被重定向
    if [ "$current" -eq "$total" ]; then
      # 最后一步持续显示旋转动画
      while true; do
        for ((i=0; i<4; i++)); do
          printf "\r[%s] %s [%d/%d] %s" "${arr[$i]}" "$step" "$current" "$total" "$dots" >&2
          printf "" >&2
          sleep 0.1
        done
      done &
      local spinner_pid=$!
      return $spinner_pid
    else
      # 普通步骤显示一次
      printf "\r[%s] %s [%d/%d] %s\n" "${arr[$index]}" "$step" "$current" "$total" "$dots" >&2
      printf "" >&2
      sleep 0.1
    fi
  }

  # 创建目录
  echo "创建目录结构..."
  dirs=(
    "tmp/Docs/AcpiSamples"
    "tmp/Utilities"
    )
  for dir in "${dirs[@]}"; do
    mkdir -p "${dir}" &>/dev/null || exit 1
  done

  efidirs=(
    "EFI/BOOT"
    "EFI/OC/ACPI"
    "EFI/OC/Drivers"
    "EFI/OC/Kexts"
    "EFI/OC/Tools"
    "EFI/OC/Resources/Audio"
    "EFI/OC/Resources/Font"
    "EFI/OC/Resources/Image"
    "EFI/OC/Resources/Label"
    )

  # Switch to parent architecture directory (i.e. Build/X64 -> Build).
  local dstdir
  dstdir="$(pwd)/tmp"
  pushd .. &>/dev/null || exit 1

  # 复制 EFI 文件
  echo "复制 EFI 文件..."
  local total_steps=11  # 修正总步骤数
  local current_step=1

  # 步骤1: 复制 EFI 文件
  show_package_progress "复制 EFI 文件" $total_steps $current_step
  for arch in "${ARCHS[@]}"; do
    for dir in "${efidirs[@]}"; do
      mkdir -p "${dstdir}/${arch}/${dir}" &>/dev/null || exit 1
    done

    # copy OpenCore main program.
    cp "${arch}/OpenCore.efi" "${dstdir}/${arch}/EFI/OC" &>/dev/null || exit 1
    printf "%s" "OpenCore" > "${dstdir}/${arch}/EFI/OC/.contentFlavour" || exit 1
    printf "%s" "Disabled" > "${dstdir}/${arch}/EFI/OC/.contentVisibility" || exit 1

    local suffix="${arch}"
    if [ "${suffix}" = "X64" ]; then
      suffix="x64"
    fi
    cp "${arch}/Bootstrap.efi" "${dstdir}/${arch}/EFI/BOOT/BOOT${suffix}.efi" &>/dev/null || exit 1
    printf "%s" "OpenCore" > "${dstdir}/${arch}/EFI/BOOT/.contentFlavour" || exit 1
    printf "%s" "Disabled" > "${dstdir}/${arch}/EFI/BOOT/.contentVisibility" || exit 1
  done
  echo ""

  # 步骤2: 复制工具和驱动
  current_step=$((current_step+1))
  show_package_progress "复制工具和驱动" $total_steps $current_step
  for arch in "${ARCHS[@]}"; do
    efiTools=(
      "BootKicker.efi"
      "ChipTune.efi"
      "CleanNvram.efi"
      "CsrUtil.efi"
      "FontTester.efi"
      "GopStop.efi"
      "KeyTester.efi"
      "ListPartitions.efi"
      "MmapDump.efi"
      "ResetSystem.efi"
      "RtcRw.efi"
      "TpmInfo.efi"
      "OpenControl.efi"
      "ControlMsrE2.efi"
      )
    for efiTool in "${efiTools[@]}"; do
      cp "${arch}/${efiTool}" "${dstdir}/${arch}/EFI/OC/Tools"/ &>/dev/null || exit 1
    done

    # Special case: OpenShell.efi
    cp "${arch}/Shell.efi" "${dstdir}/${arch}/EFI/OC/Tools/OpenShell.efi" &>/dev/null || exit 1
    cp -r "${selfdir}/Resources/" "${dstdir}/${arch}/EFI/OC/Resources"/ &>/dev/null || exit 1

    efiDrivers=(
      "ArpDxe.efi"
      "AudioDxe.efi"
      "BiosVideo.efi"
      "CrScreenshotDxe.efi"
      "Dhcp4Dxe.efi"
      "Dhcp6Dxe.efi"
      "DnsDxe.efi"
      "DpcDxe.efi"
      "Ext4Dxe.efi"
      "FirmwareSettingsEntry.efi"
      "Hash2DxeCrypto.efi"
      "HiiDatabase.efi"
      "HttpBootDxe.efi"
      "HttpDxe.efi"
      "HttpUtilitiesDxe.efi"
      "Ip4Dxe.efi"
      "Ip6Dxe.efi"
      "MnpDxe.efi"
      "Mtftp4Dxe.efi"
      "Mtftp6Dxe.efi"
      "NvmExpressDxe.efi"
      "OpenCanopy.efi"
      "OpenHfsPlus.efi"
      "OpenLegacyBoot.efi"
      "OpenLinuxBoot.efi"
      "OpenNetworkBoot.efi"
      "OpenNtfsDxe.efi"
      "OpenPartitionDxe.efi"
      "OpenRuntime.efi"
      "OpenUsbKbDxe.efi"
      "OpenVariableRuntimeDxe.efi"
      "Ps2KeyboardDxe.efi"
      "Ps2MouseDxe.efi"
      "RamDiskDxe.efi"
      "ResetNvramEntry.efi"
      "RngDxe.efi"
      "SnpDxe.efi"
      "TcpDxe.efi"
      "TlsDxe.efi"
      "ToggleSipEntry.efi"
      "Udp4Dxe.efi"
      "Udp6Dxe.efi"
      "UefiPxeBcDxe.efi"
      "UsbMouseDxe.efi"
      "Virtio10.efi"
      "VirtioBlkDxe.efi"
      "VirtioGpuDxe.efi"
      "VirtioNetDxe.efi"
      "VirtioPciDeviceDxe.efi"
      "VirtioScsiDxe.efi"
      "VirtioSerialDxe.efi"
      "XhciDxe.efi"
      )
    for efiDriver in "${efiDrivers[@]}"; do
      cp "${arch}/${efiDriver}" "${dstdir}/${arch}/EFI/OC/Drivers"/ &>/dev/null || exit 1
    done
  done
  echo ""

  # 步骤3: 复制文档和编译 ACPI
  current_step=$((current_step+1))
  show_package_progress "复制文档和编译 ACPI" $total_steps $current_step
  docs=(
    "Configuration.pdf"
    "Differences/Differences.pdf"
    "Sample.plist"
    "SampleCustom.plist"
    )
  for doc in "${docs[@]}"; do
    cp "${selfdir}/Docs/${doc}" "${dstdir}/Docs"/ &>/dev/null || exit 1
  done
  cp "${selfdir}/Changelog.md" "${dstdir}/Docs"/ &>/dev/null || exit 1
  cp -r "${selfdir}/Docs/AcpiSamples/"* "${dstdir}/Docs/AcpiSamples"/ &>/dev/null || exit 1
  echo ""

  # 步骤4: 编译 ACPI 文件
  current_step=$((current_step+1))
  show_package_progress "编译 ACPI 文件" $total_steps $current_step
  mkdir -p "${dstdir}/Docs/AcpiSamples/Binaries" &>/dev/null || exit 1
  pushd "${dstdir}/Docs/AcpiSamples/Source" &>/dev/null || exit 1
  for i in *.dsl ; do
    iasl -va "$i" &>/dev/null || exit 1
  done
  mv ./*.aml "${dstdir}/Docs/AcpiSamples/Binaries" &>/dev/null || exit 1
  popd &>/dev/null || exit 1
  echo ""

  # 步骤5: 复制工具脚本
  current_step=$((current_step+1))
  show_package_progress "复制工具脚本" $total_steps $current_step
  utilScpts=(
    "LegacyBoot"
    "CreateVault"
    "FindSerialPort"
    "macrecovery"
    "kpdescribe"
    "ShimUtils"
    )
  for utilScpt in "${utilScpts[@]}"; do
    cp -r "${selfdir}/Utilities/${utilScpt}" "${dstdir}/Utilities"/ &>/dev/null || exit 1
  done
  echo ""

  # 步骤6: 复制 LogoutHook
  current_step=$((current_step+1))
  show_package_progress "复制 LogoutHook" $total_steps $current_step
  mkdir -p "${dstdir}/Utilities/LogoutHook" &>/dev/null || exit 1
  logoutFiles=(
    "Launchd.command"
    "Launchd.command.plist"
    "README.md"
    "Legacy/nvramdump"
    )
  for file in "${logoutFiles[@]}"; do
    cp "${selfdir}/Utilities/LogoutHook/${file}" "${dstdir}/Utilities/LogoutHook"/ &>/dev/null || exit 1
  done
  echo ""

  # 步骤7: 复制 OpenDuetPkg booter
  current_step=$((current_step+1))
  show_package_progress "复制 OpenDuetPkg" $total_steps $current_step
  for arch in "${ARCHS[@]}"; do
    local tgt
    local booter
    local booter_blockio
    tgt="$(basename "$(pwd)")"
    booter="$(pwd)/../../OpenDuetPkg/${tgt}/${arch}/boot"
    booter_blockio="$(pwd)/../../OpenDuetPkg/${tgt}/${arch}/boot-blockio"

    if [ -f "${booter}" ]; then
      cp "${booter}" "${dstdir}/Utilities/LegacyBoot/boot${arch}" &>/dev/null || exit 1
    fi
    if [ -f "${booter_blockio}" ]; then
      cp "${booter_blockio}" "${dstdir}/Utilities/LegacyBoot/boot${arch}-blockio" &>/dev/null || exit 1
    fi
  done
  echo ""

  # 步骤8: 复制 EnableGop
  current_step=$((current_step+1))
  show_package_progress "复制 EnableGop" $total_steps $current_step
  eg_ver=$(get_inf_version "${selfdir}/Staging/EnableGop/EnableGop.inf") || exit 1
  egdirect_ver=$(get_inf_version "${selfdir}/Staging/EnableGop/EnableGopDirect.inf") || exit 1

  if [ "${eg_ver}" != "${egdirect_ver}" ] ; then
    echo "不匹配的EnableGop版本 (${eg_ver} 和${egdirect_ver})!"
    exit 1
  fi

  mkdir -p "${dstdir}/Utilities/EnableGop/Pre-release" &>/dev/null || exit 1
  ENABLE_GOP_GUID="3FBA58B1-F8C0-41BC-ACD8-253043A3A17F"
  ffsNames=(
    "EnableGop"
    "EnableGopDirect"
    )
  for ffsName in "${ffsNames[@]}"; do
    cp "FV/Ffs/${ENABLE_GOP_GUID}${ffsName}/${ENABLE_GOP_GUID}.ffs" "${dstdir}/Utilities/EnableGop/Pre-release/${ffsName}_${eg_ver}.ffs" &>/dev/null || exit 1
  done
  gopDrivers=(
    "EnableGop"
    "EnableGopDirect"
    )
  for file in "${gopDrivers[@]}"; do
    cp "X64/${file}.efi" "${dstdir}/Utilities/EnableGop/Pre-release/${file}_${eg_ver}.efi" &>/dev/null || exit 1
  done
  helpFiles=(
    "README.md"
    "UEFITool_Inserted_Screenshot.png"
    "vBiosInsert.sh"
  )
  for file in "${helpFiles[@]}"; do
    cp "${selfdir}/Staging/EnableGop/${file}" "${dstdir}/Utilities/EnableGop"/ &>/dev/null || exit 1
  done
  cp "${selfdir}/Staging/EnableGop/Release/"* "${dstdir}/Utilities/EnableGop"/ &>/dev/null || exit 1
  echo ""

  # 步骤9: 复制 BaseTools
  current_step=$((current_step+1))
  show_package_progress "复制 BaseTools" $total_steps $current_step
  mkdir "${dstdir}/Utilities/BaseTools" &>/dev/null || exit 1
  if [ "$(unamer)" = "Windows" ]; then
    cp "${selfdir}/UDK/BaseTools/Bin/Win32/EfiRom.exe" "${dstdir}/Utilities/BaseTools" &>/dev/null || exit 1
    cp "${selfdir}/UDK/BaseTools/Bin/Win32/GenFfs.exe" "${dstdir}/Utilities/BaseTools" &>/dev/null || exit 1
  else
    cp "${selfdir}/UDK/BaseTools/Source/C/bin/EfiRom" "${dstdir}/Utilities/BaseTools" &>/dev/null || exit 1
    cp "${selfdir}/UDK/BaseTools/Source/C/bin/GenFfs" "${dstdir}/Utilities/BaseTools" &>/dev/null || exit 1
  fi
  echo ""

  # 步骤10: 复制工具和文档
  current_step=$((current_step+1))
  show_package_progress "复制工具和文档" $total_steps $current_step
  utils=(
    "ACPIe"
    "acdtinfo"
    "macserial"
    "ocpasswordgen"
    "ocvalidate"
    "disklabel"
    "icnspack"
    )
  for util in "${utils[@]}"; do
    dest="${dstdir}/Utilities/${util}"
    mkdir -p "${dest}" &>/dev/null || exit 1
    bin="${selfdir}/Utilities/${util}/${util}"
    cp "${bin}" "${dest}" &>/dev/null || exit 1
    if [ -f "${bin}.exe" ]; then
      cp "${bin}.exe" "${dest}" &>/dev/null || exit 1
    fi
    if [ -f "${bin}.linux" ]; then
      cp "${bin}.linux" "${dest}" &>/dev/null || exit 1
    fi
  done
  cp "${selfdir}/Utilities/macserial/FORMAT.md" "${dstdir}/Utilities/macserial"/ &>/dev/null || exit 1
  cp "${selfdir}/Utilities/macserial/README.md" "${dstdir}/Utilities/macserial"/ &>/dev/null || exit 1
  cp "${selfdir}/Utilities/ocvalidate/README.md" "${dstdir}/Utilities/ocvalidate"/ &>/dev/null || exit 1
  echo ""

  # 步骤11: 构建工具和打包
  current_step=$((current_step+1))
  spinner_pid=$(show_package_progress "构建工具和打包" $total_steps $current_step)
  buildutil &>/dev/null || exit 1
  kill $spinner_pid 2>/dev/null

  pushd "${dstdir}" &>/dev/null || exit 1
  zip -qr -FS ../"OpenCore-Mod-${ver}-${2}.zip" ./* &>/dev/null || exit 1
  popd &>/dev/null || exit 1
  rm -rf "${dstdir}" &>/dev/null || exit 1

  popd &>/dev/null || exit 1
  popd &>/dev/null || exit 1
  printf "\r%s\r" "$(printf ' %.0s' {1..80})"
  echo "打包完成!"
}

cd "$(dirname "$0")" || exit 1
if [ "$ARCHS" = "" ]; then
  ARCHS=(X64)
  export ARCHS
fi
SELFPKG=OpenCorePkg
NO_ARCHIVES=0

export SELFPKG
export NO_ARCHIVES

# 下载并执行 efibuild.sh
src=$(curl -LfsS https://gitee.com/btwise/ocbuild/raw/master/efibuild.sh) || exit 1
eval "$src" || exit 1

# 验证配置文件
cd Utilities/ocvalidate || exit 1
ocv_tool=""
if [ -x ./ocvalidate ]; then
  ocv_tool=./ocvalidate
elif [ -x ./ocvalidate.exe ]; then
  ocv_tool=./ocvalidate.exe
fi

if [ -x "$ocv_tool" ]; then
  "$ocv_tool" ../../Docs/Sample.plist || abort "Sample.plist错误"
  "$ocv_tool" ../../Docs/SampleCustom.plist || abort "SampleCustom.plist错误"
fi
cd ../..

# 检查架构
cd Library/OcConfigurationLib || exit 1
echo "编译成功!"
echo "----------------------------------------------------------------"
echo "运行检查架构脚本......"
python3 ./CheckSchema.py OcConfigurationLib.c >/dev/null || abort "OccConfigurationLib.c错误"
echo "架构检查完成！"
echo "编译成功!" && open $BUILDDIR/Binaries
