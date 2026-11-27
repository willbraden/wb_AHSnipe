@echo off
rem Upload this PC's AH data (Snipe, TSM) to GitHub, to data/pc/ in the repo.
rem Exit WoW first: the game only writes its saved data when it closes.
rem The first run asks for your GitHub token and saves it (see README).
setlocal
set "WOW=C:\Program Files (x86)\World of Warcraft\_forever_"
set "SCRIPT=C:\Users\willbraden\Documents\Wills PC\Wow Forever\AH Tracking\upload-data.py"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0upload-data.py"
echo Uploading AH data to GitHub...
echo.
rem "py" can be the Python launcher or python.exe itself, so no "-3" flag.
where py >nul 2>nul && (py "%SCRIPT%" --machine pc --wow "%WOW%" --ask & goto done)
where python >nul 2>nul && (python "%SCRIPT%" --machine pc --wow "%WOW%" --ask & goto done)
echo Python isn't installed. Get "Python 3" from the Microsoft Store, then run this again.
:done
echo.
pause
