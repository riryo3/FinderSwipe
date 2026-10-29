@echo off
rem Windows 標準搭載の C# コンパイラでビルドする(追加インストール不要)
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo csc.exe が見つかりませんでした。.NET Framework が必要です。
  pause
  exit /b 1
)
"%CSC%" /nologo /platform:x64 /target:exe /out:FinderSwipeReceiver.exe FinderSwipeReceiver.cs
if errorlevel 1 (
  echo ビルドに失敗しました。
  pause
  exit /b 1
)
echo ビルド完了: FinderSwipeReceiver.exe
echo 実行すると初回だけファイアウォールの許可を求められます。プライベートネットワークで許可してください。
pause
