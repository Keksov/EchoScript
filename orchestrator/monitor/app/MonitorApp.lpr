program MonitorApp;

{$mode objfpc}{$H+}

uses
  {$ifdef UNIX}
  cthreads,
  {$endif}
  Interfaces,
  Forms,
  main_form;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'Daemon Monitor';
  Application.Initialize;
  Application.CreateForm(TMonitorForm, MonitorForm);
  Application.Run;
end.
