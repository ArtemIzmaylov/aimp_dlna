{*********************************************}
{*                                           *}
{*              AIMP DLNA Plugin             *}
{*                                           *}
{*            (c) Artem Izmaylov             *}
{*                 2023-2023                 *}
{*                www.aimp.ru                *}
{*                                           *}
{*********************************************}

library aimp_dlna;

{$R *.res}

uses
  apiPlugin,
  AIMP.DLNA.Plugin in 'AIMP.DLNA.Plugin.pas',
  AIMP.DLNA.Plugin.ML in 'AIMP.DLNA.Plugin.ML.pas',
  UPNPLib_TLB in 'UPNPLib_TLB.pas';

  function AIMPPluginGetHeader(out Header: IAIMPPlugin): HRESULT; stdcall;
  begin
    Header := TDLNAPlugin.Create;
    Result := S_OK;
  end;

exports
  AIMPPluginGetHeader;
begin
end.
