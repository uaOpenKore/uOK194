:��������� ��������� ����� fields �� ���� �������� .fld � ������ ����;
:����������� ����: http://rofan.ru/viewtopic.php?t=1409 
@set my7z=C:\Soft\7-Zip\7z.exe
@For %%a In (*.fld) Do @%my7z% a -tgzip -mx9 %%a.gz %%a
:-------------------
:������������ - ������ NTFS (�����������) :
:compact /C /S *.dist
:compact /C /S *.fld
:compact /C /S *.pl
:compact /C /S *.pm
:compact /C /S *.bmp
