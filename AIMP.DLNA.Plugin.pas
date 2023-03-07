{*********************************************}
{*                                           *}
{*              AIMP DLNA Plugin             *}
{*                                           *}
{*            (c) Artem Izmaylov             *}
{*                 2023-2023                 *}
{*                www.aimp.ru                *}
{*                                           *}
{*********************************************}

unit AIMP.DLNA.Plugin;

{$I AIMP.DLNA.inc}

interface

uses
  System.SysUtils,
  // API
  apiCore,
  apiMusicLibrary,
  apiObjects,
  apiPlugin,
  apiWrappers,
  // Wrappers
  AIMPCustomPlugin,
  // DLNA
  AIMP.DLNA.Plugin.ML;

type

  { TDLNAPlugin }

  TDLNAPlugin = class(TAIMPCustomPlugin)
  protected
    function InfoGet(Index: Integer): PWideChar; override; stdcall;
    function InfoGetCategories: Cardinal; override; stdcall;
    function Initialize(Core: IAIMPCore): HRESULT; override; stdcall;
    procedure Finalize; override; stdcall;
  end;

implementation

{ TDLNAPlugin }

function TDLNAPlugin.InfoGet(Index: Integer): PWideChar;
begin
  case Index of
    AIMP_PLUGIN_INFO_NAME:
      Result := 'DLNA Client v1.0b';
    AIMP_PLUGIN_INFO_SHORT_DESCRIPTION:
      Result := 'Provides an ability to play music from local DLNA servers';
    AIMP_PLUGIN_INFO_AUTHOR:
      Result := 'Artem Izmaylov';
  else
    Result := '';
  end;
end;

function TDLNAPlugin.InfoGetCategories: Cardinal;
begin
  Result := AIMP_PLUGIN_CATEGORY_ADDONS;
end;

function TDLNAPlugin.Initialize(Core: IAIMPCore): HRESULT;
begin
  if not Supports(Core, IAIMPServiceMusicLibrary) then
    Exit(E_NOTIMPL);

  inherited Initialize(Core);
  Core.RegisterExtension(IAIMPServiceMusicLibrary, TDLNAMusicLibraryExtension.Create);
  Result := S_OK;
end;

procedure TDLNAPlugin.Finalize;
begin
  inherited Finalize;
end;

end.
