@set mywinrar=c:\Soft\WRar\WinRAR.exe
@set my7z=C:\Soft\7-Zip\7z.exe
@set mysvn=194SVN5622
@set mysvndrive=D:
@set mypath2svn=%mysvndrive%\ro-proj\!
@set mytitle=mix\pack-title.txt
@set myreldir=c:\Temp\Release
@rem -----------------------------------
@rem ** Special for: http://rofan.ru **
@rem ** упаковка релиза одним кликом **
@rem ** єяръютър Ёхышчр юфэшь ъышъюь **
@rem -----------------------------------
@echo PACKING OpenKore %mypath2svn%\%mysvn% ...
@echo.|time
@%mysvndrive%
@cd %mypath2svn%
@rem #full:#
@%mywinrar% a -s -r -m5 -md4096 %TEMP%\%mysvn%.rar %mysvn% -z%mypath2svn%\%mysvn%\%mytitle%
@rem #update:#
:@%mywinrar% a -s -r -m5 -md4096 %TEMP%\%mysvn%upd.rar %mysvn% -z%mypath2svn%\%mysvn%\%mytitle% -x@%mypath2svn%\%mysvn%\mix\filesupdexcl.txt 
@%HOMEDRIVE%
@cd %TEMP%
@rem #full:#
@%mywinrar% m -afzip %myreldir%\%mysvn%.zip %mysvn%.rar -z%mypath2svn%\%mysvn%\%mytitle%
@rem #update:#
:@%mywinrar% m -afzip %myreldir%\%mysvn%upd.zip %mysvn%upd.rar -z%mypath2svn%\%mysvn%\%mytitle%
@echo.|time
@echo READY COMRAD
@pause
