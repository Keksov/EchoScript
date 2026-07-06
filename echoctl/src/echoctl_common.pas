unit echoctl_common;

{ Общие мелочи echoctl: коды возврата (контракт для обёртки и смоков) и вывод ошибок. }

{$mode objfpc}{$H+}

interface

const
  EXIT_OK       = 0;  { успех }
  EXIT_RUNTIME  = 1;  { непойманное исключение }
  EXIT_USAGE    = 2;  { ошибка аргументов/валидации }
  EXIT_NOTIMPL  = 3;  { распознанная, но не реализованная подкоманда }

procedure writeErr(const aMessage: string);

{ writeErr('echoctl: ' + aMessage) и возврат EXIT_USAGE — для валидаций. }
function fail(const aMessage: string): Integer;

implementation

procedure writeErr(const aMessage: string);
begin
  WriteLn(StdErr, aMessage);
end;

function fail(const aMessage: string): Integer;
begin
  writeErr('echoctl: ' + aMessage);
  Result := EXIT_USAGE;
end;

end.
