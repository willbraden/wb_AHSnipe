@echo off
rem Upload this PC's AH data (Snipe, TSM) to GitHub, to data/pc/ in the repo.
rem Exit WoW first: the game only writes its saved data when it closes.
rem Needs a GitHub token in %APPDATA%\wb_AHSnipe\github-token (see README).
setlocal
set "WOW=C:\Program Files (x86)\World of Warcraft\_forever_"
set "HERE=%~dp0"
where py >nul 2>nul && (py -3 "%HERE%upload-data.py" --machine pc --wow "%WOW%" & goto done)
where python >nul 2>nul && (python "%HERE%upload-data.py" --machine pc --wow "%WOW%" & goto done)
echo Python isn't installed. Get it from the Microsoft Store ("Python 3"), then run this again.
:done
echo.
pause
