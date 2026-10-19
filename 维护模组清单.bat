@echo off
rem ============================================================================
rem  Coco 整合包 - 模组清单同步工具 (启动器)
rem
rem  用法
rem    双击                          交互式, 自动找同级的 Coco_Minecraft_CustomModPack
rem    维护模组清单.bat -DryRun       只看差异, 不写文件
rem    维护模组清单.bat -NoSide       跳过 side 校正
rem    维护模组清单.bat -NoPrune      不删除失效条目
rem    维护模组清单.bat -All          不逐个询问, 直接处理全部新增模组
rem    维护模组清单.bat -PackDir "D:\包目录"   指定其他 packwiz 包
rem
rem  处理完成后会询问是否立即提交并推送, 选否则只保留本地改动
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0维护模组清单.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 维护模组清单.ps1
    echo        请把它和本 bat 放在同一个目录
    pause
    exit /b 1
)

title Coco 整合包 - 模组清单同步工具
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" goto :failed

rem 由 开发工具.bat 调用时存在此变量, 推送询问交由菜单负责
if defined COCO_NO_PUSH_PROMPT goto :done

rem 结束前询问是否推送, 需要显式输入 y
echo.
set "_PUSH="
set /p "_PUSH=要现在提交并推送元数据仓吗 [y/N] : "
if /i not "%_PUSH%"=="y" goto :skipped
if /i "%_PUSH%"=="no" goto :skipped

if not exist "%~dp0推送元数据.bat" (
    echo [错误] 找不到 推送元数据.bat, 无法推送
    goto :done
)
call "%~dp0推送元数据.bat"
goto :done

:skipped
echo.
echo [信息] 已跳过推送, 改动仍保留在 Coco_Minecraft_CustomModPack 工作区
echo        需要推送时运行 推送元数据.bat, 或在仓库里手动 git add / commit / push
goto :done

:failed
echo.
echo [提示] 退出码 %RC%, 未进入推送环节, 按任意键关闭窗口
pause >nul

:done
endlocal
exit /b %RC%