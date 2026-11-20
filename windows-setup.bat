@echo off
mode con cp select=437 >nul

rem 还原 setup.exe
rename X:\setup.exe.disabled setup.exe

rem 等待 10 秒才自动安装
cls
for /l %%i in (10,-1,1) do (
    echo Press Ctrl+C within %%i seconds to cancel the automatic installation.
    call :sleep 1000
    cls
)

rem win7 find 命令在 65001 代码页下有问题，仅限 win 7
rem findstr 就正常，但安装程序又没有 findstr
rem echo a | find "a"

rem 使用高性能模式
rem https://learn.microsoft.com/windows-hardware/manufacture/desktop/capture-and-apply-windows-using-a-single-wim
rem win8 pe 没有 powercfg
powercfg /s SCHEME_MIN 2>nul

rem 两个同样的驱动，PE 下只会使用先加载的那个
rem https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/limitations-dollar-sign-winpedriver-dollar-sign

rem 因此先安装用户添加的 SCSI 驱动
rem 可以用 forfiles /p X:\custom_drivers /m *.inf /c "cmd /c echo @path"
rem 不可以用 for %%F in ("X:\custom_drivers\*\*.inf")
if exist X:\custom_drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\custom_drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )
)

rem 后安装脚本自动添加的 SCSI 驱动
if exist X:\drivers\ (
    for /f "delims=" %%F in ('dir /s /b "X:\drivers\*.inf" 2^>nul') do (
        call :drvload_if_scsi "%%~F"
    )

    rem 官网写了可以安装但仅会加载关键驱动
    rem Gcore 的 virtio-gpu 在安装时没有显示
    rem 即使安装时加载了显卡驱动
    rem 进入系统后才有显示
    rem find /i "viogpudo" "%%~F" >nul
    rem if not errorlevel 1 (
    rem     drvload "%%~F"
    rem )
)

rem 等待加载分区
call :sleep 5000
echo rescan | diskpart
call :sleep 5000

rem 获取 ProductType
rem for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\ProductOptions" /v ProductType') do (
rem     set "ProductType=%%a"
rem )

rem 获取 installer 卷 id
for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| find /i " @installer_part_label@ "') do (
    set "VolIndex=%%a"
)

rem 及时退出
if "%VolIndex%"=="" (
    echo Error: Cannot find installer partition. >&2
    exit /b 1
)

rem 将 installer 分区设为 Y 盘
(echo select vol %VolIndex% & echo assign letter=Y) | diskpart

rem 旧版安装程序会自动在 C 盘设置虚拟内存
rem 新版安装程序(24h2)不会自动设置虚拟内存
rem 在 installer 分区创建虚拟内存，不用白不用
call :createPageFile

rem 查看虚拟内存
rem wmic pagefile

rem 获取主硬盘 id
rem vista pe 没有 wmic，因此用 diskpart

rem 法语版 win7 diskpart 始终输出法语，即使设置了 chcp 437，因此不能用这个方法
rem (echo select vol %VolIndex% & echo list disk) | diskpart | find "* Disk " > X:\disk.txt
rem for /f "tokens=3" %%a in (X:\disk.txt) do (
rem     set "DiskIndex=%%a"
rem )

rem PE 下没有 findstr，因此不能从 diskpart 的输出直接选出开头为 * 的行，要用复杂的方法取出磁盘编号

rem 输出 diskpart 结果到文件
(echo select vol %VolIndex% & echo list disk) | diskpart | find "* " > X:\disk.txt
type X:\disk.txt

rem 逐行读取文件
setlocal enabledelayedexpansion
for /f "delims=" %%a in (X:\disk.txt) do (
    set "line=%%a"

    rem 寻找 * 开头的行
    call :is_x_starts_with_char_y "!line!" "*" && (
        rem 注意在 for %%b in (!safe_line!) do 中 * 会展开成文件列表，因此要先删除 *
        rem 下面用的方法是用 * 作为分割符，获取 * 后面的第一列

        rem for /f 会自动忽略行首的分隔符
        for /f "tokens=1 delims=*" %%i in ("!line!") do (
            set "safe_line=%%i"
        )

        rem 遍历每一列，找到是数字的那一列，就是磁盘编号
        for %%b in (!safe_line!) do (
            call :is_number "%%b" && (
                set "DiskIndex=%%b"
                goto :found_main_disk
            )
        )

        rem 普通 for 是把“一段话”里的“每个词”排成队，让一个变量（%%b）轮流去当这些词
        rem for /f   是把“一段话”拆成“几个零件”存在不同的变量里（%%i, %%j...）
    )
)

:not_found_main_disk
echo Error: Cannot find main disk. >&2
exit /b 1

:found_main_disk
del X:\disk.txt
endlocal & set "DiskIndex=%DiskIndex%"

rem pe 下没有 mountvol

rem 判断 efi 还是 bios
rem https://learn.microsoft.com/windows-hardware/manufacture/desktop/boot-to-uefi-mode-or-legacy-bios-mode
wpeutil UpdateBootInfo
reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType | find "0x2" && (
    set BootType=efi
) || (
    set BootType=bios
)

rem 这个变量会被 trans.sh 修改
set is4kn=0
if "%is4kn%"=="1" (
    set EFISize=260
) else (
    set EFISize=100
)

rem 重新分区/格式化
(if "%BootType%"=="efi" (
    echo select disk %DiskIndex%

    rem del
    echo select part 1
    echo delete part override
    echo select part 2
    echo delete part override
    echo select part 3
    echo delete part override

    rem 1
    echo create part efi size=%EFISize%
    echo format fs=fat32 quick

    rem 2
    echo create part msr size=16

    rem 3
    echo create part primary
    echo format fs=ntfs quick
    rem echo assign letter=Z

) else (
    echo select disk %DiskIndex%

    rem del
    echo select part 1
    echo delete part override

    rem 1
    echo create part primary
    echo format fs=ntfs quick
    echo active
    rem echo assign letter=Z

)) > X:\diskpart.txt

rem 使用 diskpart /s ，出错后不会执行剩下的 diskpart 命令
rem 但是返回值始终是 0
diskpart /s X:\diskpart.txt
del X:\diskpart.txt

rem 盘符
rem X boot.wim (ram)
rem Y installer
rem Z os

rem 获取 BuildNumber
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do (
    set "BuildNumber=%%a"
)

rem 旧版安装程序会自动在C盘设置虚拟内存，新版安装程序(24h2)不会
rem 如果不创建虚拟内存，1g 内存的机器安装时会报错/杀进程
if %BuildNumber% GEQ 26040 (
    rem 已经在 installer 分区创建了虚拟内存，约等于 boot.wim 的大小，因此这步不需要
    rem vista/2008 没有删除 boot.wim，200M预留空间-(文件系统占用+驱动占用)后，实测能创建1个64M虚拟内存文件
    rem call :createPageFileOnZ
)

rem 设置应答文件的主硬盘 id
set "file=X:\windows.xml"
set "tempFile=X:\tmp.xml"

set "search=%%disk_id%%"
set "replace=%DiskIndex%"

(for /f "delims=" %%i in (%file%) do (
    set "line=%%i"

    setlocal EnableDelayedExpansion
    echo !line:%search%=%replace%!
    endlocal

)) > %tempFile%
move /y %tempFile% %file%


rem https://github.com/pbatard/rufus/issues/1990
for %%a in (RAM TPM SecureBoot) do (
    reg add HKLM\SYSTEM\Setup\LabConfig /t REG_DWORD /v Bypass%%aCheck /d 1 /f
)

rem 设置
set ForceOldSetup=0
set UseDism=0
set WimImageName=@image_name@
set EnableUnattended=1
set EnableEMS=0

rem 运行 ramdisk X:\setup.exe 的话
rem vista 会找不到安装源
rem server 23h2 会无法运行
rem 使用 /installfrom 可以解决?

rem 有的精简版 iso install.wim 根目录没有 setup.exe
rem https://github.com/bin456789/reinstall/issues/578

if "%ForceOldSetup%"=="1" if exist Y:\sources\setup.exe (
    set setup=Y:\sources\setup.exe
    goto :SetupExeFound
)
if exist Y:\setup.exe (
    set setup=Y:\setup.exe
) else if exist Y:\sources\setup.exe (
    set setup=Y:\sources\setup.exe
) else if exist X:\setup.exe (
    set setup=X:\setup.exe
) else (
    echo "Error: setup.exe not found." >&2
    exit /b 1
)
:SetupExeFound

if "%EnableUnattended%"=="1" (
    set Unattended=/unattend:X:\windows.xml
)

rem 新版安装程序默认开了 Compact OS

rem 新版安装程序不会创建 BIOS MBR 引导
rem 因此要回退到旧版，或者手动修复 MBR
rem server 2025 + bios 也是
rem 但是 server 2025 官网写支持 bios
rem TODO: 使用 ms-sys 可以不修复？
if %BuildNumber% GEQ 26040 if "%BootType%"=="bios" (
    rem set ForceOldSetup=1
    bootrec /fixmbr
)

rem 旧版安装程序不会创建 winre 分区
rem 新版安装程序会创建 winre 分区
rem winre 分区创建在 installer 分区前面
rem 禁止 winre 分区后，winre 储存在 C 盘，依然有效
if %BuildNumber% GEQ 26040 if "%ForceOldSetup%"=="0" (
    set ResizeRecoveryPartition=/ResizeRecoveryPartition Disable
)

rem 为 windows server 打开 EMS/SAC
rem 普通 windows 没有自带 SAC 组件，暂不处理
rem 现在通过 trans.sh 准确检测系统是否有 SAC 组件，有则修改 EnableEMS 变量打开 EMS
if "%EnableEMS%"=="1" (
    rem set EMS=/EMSPort:UseBIOSSettings /EMSBaudRate:115200
    set EMS=/EMSPort:COM1 /EMSBaudRate:115200
)

rem === PATCH hayanart/reinstall: pre-flight + setup.exe failure capture ===
if exist Y:\sources\install.wim goto :wim_found
if exist Y:\sources\install.esd goto :wim_found
echo [PATCH] FATAL: install.wim/install.esd not found in Y:\sources\ >&2
echo [PATCH] Y: drive contents: >&2
dir Y:\sources\ >&2
echo [PATCH] Halting - setup.exe will NOT run. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b 1
:wim_found
if exist Y:\sources\install.wim set "wimfile=Y:\sources\install.wim"
if not exist Y:\sources\install.wim set "wimfile=Y:\sources\install.esd"
echo [PATCH] Pre-flight OK: install source found.
dism /Get-ImageInfo /ImageFile:%wimfile% > X:\wiminfo.txt 2>nul
find /i "Index :" X:\wiminfo.txt >nul 2>nul
if errorlevel 1 goto :wiminfo_skip
if "%WimImageName%"=="@image_name@" (
    echo [PATCH] FATAL: image name placeholder was not replaced by trans.sh - cannot verify image. >&2
    echo [PATCH] Halting - setup.exe will NOT run. >&2
    echo [PATCH] Press any key to drop to a command prompt for inspection.
    pause
    exit /b 1
)
if "%WimImageName%"=="" (
    echo [PATCH] FATAL: image name is empty - cannot verify image. >&2
    echo [PATCH] Halting - setup.exe will NOT run. >&2
    echo [PATCH] Press any key to drop to a command prompt for inspection.
    pause
    exit /b 1
)
find /i "%WimImageName%" X:\wiminfo.txt >nul 2>nul
if not errorlevel 1 goto :wiminfo_ok
echo [PATCH] FATAL: image name not found in install.wim - see X:\wiminfo.txt >&2
type X:\wiminfo.txt >&2
echo [PATCH] Halting - setup.exe will NOT run. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b 1
:wiminfo_ok
echo [PATCH] Image name verified in install.wim.
:wiminfo_skip
if exist X:\wiminfo.txt del X:\wiminfo.txt
rem DISM bypass: skip setup.exe entirely when UseDism=1 (set by trans.sh
rem from --use-dism). setup.exe dies opaquely on some images.
if "%UseDism%"=="1" goto :dism_path
echo on
%setup% %ResizeRecoveryPartition% %EMS% %Unattended%
set "setup_rc=%ERRORLEVEL%"
@echo off
echo.
echo [PATCH] setup.exe exited with code %setup_rc%.
echo [PATCH] Preserving setup logs to Y:\setuplogs\ ...
if not exist Y:\setuplogs\ mkdir Y:\setuplogs\
if exist "X:\$WINDOWS.~BT\Sources\Panther\setupact.log" copy /y "X:\$WINDOWS.~BT\Sources\Panther\setupact.log" Y:\setuplogs\ >nul
if exist "X:\$WINDOWS.~BT\Sources\Panther\setuperr.log" copy /y "X:\$WINDOWS.~BT\Sources\Panther\setuperr.log" Y:\setuplogs\ >nul
if exist X:\Windows\Panther\*.log copy /y X:\Windows\Panther\*.log Y:\setuplogs\ >nul
echo setup_rc=%setup_rc% > Y:\setup-result.txt
echo setup=%setup% >> Y:\setup-result.txt
echo boot_type=%BootType% disk=%DiskIndex% >> Y:\setup-result.txt
dir Y:\setuplogs\ >> Y:\setup-result.txt 2>nul
if "%setup_rc%"=="0" goto :setup_rc_ok
echo [PATCH] ERROR: setup.exe FAILED with exit code %setup_rc%. >&2
echo [PATCH] Logs preserved in Y:\setuplogs\ - see setuperr.log and setupact.log. >&2
echo [PATCH] Halting - NOT rebooting into a possibly dead disk. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b %setup_rc%
:setup_rc_ok
echo [PATCH] setup.exe returned 0 - verifying boot files on the OS partition...
if "%BootType%"=="bios" goto :check_boot_bios
goto :check_boot_efi
:check_boot_bios
(echo select disk %DiskIndex% & echo select part 1 & echo assign letter=Z) | diskpart >nul
if exist Z:\bootmgr if exist Z:\Boot\BCD goto :boot_ok
if exist C:\bootmgr if exist C:\Boot\BCD goto :boot_ok
if exist D:\bootmgr if exist D:\Boot\BCD goto :boot_ok
echo [PATCH] ERROR: bootmgr or Boot BCD NOT found on OS partition - Windows did not install. >&2
echo setup_rc=%setup_rc% bootmgr_or_bcd=missing > Y:\setup-failed.txt
echo [PATCH] Halting - NOT rebooting into a dead disk. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b 1
:check_boot_efi
(echo select disk %DiskIndex% & echo select part 3 & echo assign letter=Z) | diskpart >nul
if exist Z:\Windows\System32\winload.exe goto :boot_ok
if exist C:\Windows\System32\winload.exe goto :boot_ok
echo [PATCH] ERROR: Windows files NOT found on OS partition - Windows did not install. >&2
echo setup_rc=%setup_rc% winload=missing > Y:\setup-failed.txt
echo [PATCH] Halting - NOT rebooting into a dead disk. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b 1
:boot_ok
echo [PATCH] Boot files OK. Setup succeeded.
echo [PATCH] Rebooting into the installed Windows...
wpeutil reboot
exit /b 0





rem === PATCH hayanart/reinstall: DISM bypass (UseDism=1) ===
rem setup.exe dies opaquely on some images (new .NET setup.exe: 0xC0000135
rem missing mscoree.dll; old setup.exe: exit 255, no logs either time).
rem DISM applies the image directly and reports real errors.
:dism_path
echo [PATCH] DISM path: bypassing setup.exe (UseDism=1).
echo [PATCH] Image: %WimImageName%
rem Assign a fixed letter to the OS partition so DISM has a stable target.
rem BIOS: part 1 is the OS partition. EFI: part 3 is the OS partition,
rem part 1 is the EFI system partition.
if "%BootType%"=="bios" goto :dism_assign_bios
(echo select disk %DiskIndex% & echo select part 3 & echo assign letter=Z) | diskpart >nul
(echo select disk %DiskIndex% & echo select part 1 & echo assign letter=S) | diskpart >nul
goto :dism_assign_done
:dism_assign_bios
(echo select disk %DiskIndex% & echo select part 1 & echo assign letter=Z) | diskpart >nul
:dism_assign_done
if not exist Z:\ (
    echo [PATCH] FATAL: cannot assign drive letter Z to the OS partition. >&2
    echo [PATCH] Halting - DISM has no target. >&2
    echo [PATCH] Press any key to drop to a command prompt for inspection.
    pause
    exit /b 1
)
echo [PATCH] Applying image with DISM - this takes several minutes...
echo on
dism /Apply-Image /ImageFile:%wimfile% /Name:"%WimImageName%" /ApplyDir:Z:\
set "dism_rc=%ERRORLEVEL%"
@echo off
echo.
echo [PATCH] dism /Apply-Image exited with code %dism_rc%.
echo method=dism > Y:\setup-result.txt
echo image=%WimImageName% >> Y:\setup-result.txt
echo dism_apply_rc=%dism_rc% >> Y:\setup-result.txt
echo wimfile=%wimfile% boot_type=%BootType% disk=%DiskIndex% >> Y:\setup-result.txt
if "%dism_rc%"=="0" goto :dism_apply_ok
echo [PATCH] ERROR: dism /Apply-Image FAILED with exit code %dism_rc%. >&2
echo [PATCH] Preserving DISM logs to Y:\setuplogs\ ... >&2
if not exist Y:\setuplogs\ mkdir Y:\setuplogs\
if exist X:\Windows\Logs\DISM\dism.log copy /y X:\Windows\Logs\DISM\dism.log Y:\setuplogs\ >nul
if exist Z:\Windows\Logs\DISM\dism.log copy /y Z:\Windows\Logs\DISM\dism.log Y:\setuplogs\ >nul
echo method=dism dism_apply_rc=%dism_rc% > Y:\setup-failed.txt
echo [PATCH] Halting - NOT rebooting into a possibly dead disk. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b %dism_rc%
:dism_apply_ok
if exist Z:\Windows\Setup\State\State.ini find /i "ImageState" Z:\Windows\Setup\State\State.ini >> Y:\setup-result.txt 2>nul
rem --- Drivers: inject VirtIO/SCSI + net drivers into the offline image.
rem Best-effort: one bad driver must not kill the install; the Panther
rem unattend + first boot still apply the rest. (Ghost lost its network
rem driver before - without this, first boot has no NIC and no RDP.)
if not exist X:\drivers\ goto :skip_drv1
echo [PATCH] Injecting drivers from X:\drivers\ ...
dism /Image:Z:\ /Add-Driver /Driver:X:\drivers /Recurse
set "drv_rc=%ERRORLEVEL%"
echo drivers_rc=%drv_rc% >> Y:\setup-result.txt
if not "%drv_rc%"=="0" echo [PATCH] WARNING: driver injection from X:\drivers\ returned %drv_rc% - continuing. >&2
:skip_drv1
if not exist X:\custom_drivers\ goto :skip_drv2
echo [PATCH] Injecting drivers from X:\custom_drivers\ ...
dism /Image:Z:\ /Add-Driver /Driver:X:\custom_drivers /Recurse
set "drv2_rc=%ERRORLEVEL%"
echo custom_drivers_rc=%drv2_rc% >> Y:\setup-result.txt
if not "%drv2_rc%"=="0" echo [PATCH] WARNING: driver injection from X:\custom_drivers\ returned %drv2_rc% - continuing. >&2
:skip_drv2
rem --- Apply specialize + offlineServicing settings offline (RDP listener,
rem firewall group, drivers). Best-effort: a stripped image may lack some
rem unattend components; the Panther copy below is the primary mechanism
rem and first boot applies the same passes.
echo [PATCH] Applying unattend offline (specialize + offlineServicing)...
dism /Image:Z:\ /Apply-Unattend:X:\windows.xml
set "unattend_rc=%ERRORLEVEL%"
echo unattend_rc=%unattend_rc% >> Y:\setup-result.txt
if not "%unattend_rc%"=="0" echo [PATCH] WARNING: dism /Apply-Unattend returned %unattend_rc% - continuing, first boot will apply the unattend from Panther. >&2
rem --- First boot must process specialize + oobeSystem (Administrator
rem password, RDP, OOBE skip). setup.exe normally stages the unattend
rem here; the DISM path does it explicitly. HARD FAIL if the copy fails:
rem without this file the admin password is never set.
if not exist Z:\Windows\Panther\ mkdir Z:\Windows\Panther\
copy /y X:\windows.xml Z:\Windows\Panther\unattend.xml >nul
if not errorlevel 1 goto :panther_ok
echo [PATCH] FATAL: cannot copy unattend to Panther - admin password would never be set. >&2
echo [PATCH] Halting - NOT rebooting. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b 1
:panther_ok
echo [PATCH] Unattend staged at Panther - first boot will set the admin password.
rem --- SetupComplete.cmd safety net (runs as SYSTEM at end of setup):
rem enable RDP, open the RDP firewall rule, set WIB timezone, make sure
rem Administrator is active. The password itself comes ONLY from the
rem Panther unattend (oobeSystem) - never written here or in any log.
if not exist Z:\Windows\Setup\Scripts\ mkdir Z:\Windows\Setup\Scripts\
if not exist Z:\Windows\Setup\Scripts\SetupComplete.cmd echo @echo off > Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo. >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo rem [PATCH-DISM] RDP safety net - appended by windows-setup.bat >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo netsh advfirewall firewall set rule group="remote desktop" new enable=Yes >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo tzutil /s "SE Asia Standard Time" >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo net user administrator /active:yes >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
echo del "%%~f0" >> Z:\Windows\Setup\Scripts\SetupComplete.cmd
rem --- Offline registry: enable the RDP listener even if first boot never
rem runs specialize (non-sysprepped image). Best-effort; the Panther
rem unattend + SetupComplete above are the primary mechanisms.
reg load HKLM\OFFLINE_SYSTEM Z:\Windows\System32\config\SYSTEM >nul 2>nul
if errorlevel 1 goto :skip_offline_reg
reg add "HKLM\OFFLINE_SYSTEM\ControlSet001\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul
set "offreg_rc=%ERRORLEVEL%"
reg unload HKLM\OFFLINE_SYSTEM >nul 2>nul
echo offline_reg_rc=%offreg_rc% >> Y:\setup-result.txt
if not "%offreg_rc%"=="0" echo [PATCH] WARNING: offline RDP registry edit returned %offreg_rc% - continuing. >&2
:skip_offline_reg
rem --- Create boot files. BIOS: MBR boot on the OS partition itself.
echo [PATCH] Creating boot files with bcdboot...
if "%BootType%"=="bios" goto :dism_bcd_bios
bcdboot Z:\Windows /s S: /f UEFI
goto :dism_bcd_done
:dism_bcd_bios
bcdboot Z:\Windows /s Z: /f BIOS
:dism_bcd_done
set "bcd_rc=%ERRORLEVEL%"
echo bcdboot_rc=%bcd_rc% >> Y:\setup-result.txt
if "%bcd_rc%"=="0" goto :dism_bcd_ok
echo [PATCH] ERROR: bcdboot FAILED with exit code %bcd_rc%. >&2
echo [PATCH] Halting - NOT rebooting into a possibly dead disk. >&2
echo [PATCH] Press any key to drop to a command prompt for inspection.
pause
exit /b %bcd_rc%
:dism_bcd_ok
echo [PATCH] DISM install complete - verifying boot files on the OS partition...
set "setup_rc=%dism_rc%"
if "%BootType%"=="bios" goto :check_boot_bios
goto :check_boot_efi


:is_number
rem 尝试转换字符串为数字，如果转换失败则说明不是数字
rem 如果转换失败，num 是 0
rem 这不影响参数是 0 时的判断
set /a "num=%~1" >nul 2>nul
if "%num%"=="%~1" (
    exit /b 0
)
exit /b 1

:is_x_starts_with_char_y
set "tempStr=%~1"
if "%tempStr:~0,1%"=="%~2" (
   exit /b 0
)
exit /b 1

:sleep
rem 没有加载网卡驱动，无法用 ping 来等待
rem 没有 timeout 命令
rem timeout /t 10 /nobreak
echo wscript.sleep(%~1) > X:\sleep.vbs
cscript //nologo X:\sleep.vbs
del X:\sleep.vbs
exit /b

:createPageFile
rem 尽量填满空间，pagefile 默认 64M
for /l %%i in (1, 1, 100) do (
    wpeutil CreatePageFile /path=Y:\pagefile%%i.sys >nul 2>nul && echo Created pagefile%%i.sys || exit /b
)
exit /b

:createPageFileOnZ
wpeutil CreatePageFile /path=Z:\pagefile.sys /size=512
exit /b

:drvload_if_scsi
rem 不要查找 Class=SCSIAdapter 因为有些驱动等号两边有空格
find /i "SCSIAdapter" "%~1" >nul
if not errorlevel 1 (
    rem 有 N 种方法安装驱动
    rem 1. dism /online /add-driver /driver:"%~1"     # PE 不支持 /online 添加驱动
    rem 2. pnputil -i -a "%~1"
    rem 3. devcon
    rem 4. dpinst
    rem 5. drvload 官方推荐 https://learn.microsoft.com/windows-hardware/manufacture/desktop/drvload-command-line-options
    drvload "%~1"
)
exit /b
