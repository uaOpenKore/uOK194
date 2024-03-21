@rem ----------------------------------
@rem ** Special for: http://rofan.ru **
@rem ----------------------------------
:rem ***** examples *****
:rem Для запуска нужен ActivePerl + установка всех модулей, требуемых OpenKore'е
:rem ********************
:openkore.pl --interface=Console
:openkore.pl --interface=Console --no-connect
:openkore.pl --interface=Win32
:openkore.pl --interface=Wx
:openkore.pl
@echo.
@echo Press any key to continue...
@pause > nul