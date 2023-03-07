{*********************************************}
{*                                           *}
{*              AIMP DLNA Plugin             *}
{*                                           *}
{*            (c) Artem Izmaylov             *}
{*                 2023-2023                 *}
{*                www.aimp.ru                *}
{*                                           *}
{*********************************************}

unit AIMP.DLNA.Plugin.ML;

{$I AIMP.DLNA.inc}
{$MESSAGE 'TODO - support for album art thumbnails'}

interface

uses
  Winapi.ActiveX,
  Winapi.Windows,
  // API
  apiObjects,
  apiFileManager,
  apiMusicLibrary,
  apiWrappers,
  apiWrappersGUI,
  // System
  System.Generics.Collections,
  System.Variants,
  System.SysUtils,
  // ACL
  ACL.FileFormats.XML,
  ACL.Threading,
  ACL.Utils.Common,
  ACL.Utils.FileSystem,
  ACL.Utils.Strings,
  // UPnP
  UPNPLib_TLB;

type
  { TDLNAEntry }

  TDLNAEntry = record
    Album: string;
    AlbumArtist: string;
    Artist: string;
    Bitrate: Integer;
    Clazz: string;
    Duration: Single;
    Genre: string;
    ID: string;
    Size: Int64;
    Title: string;
    Url: string;
    Year: string;

    class function Create(ANode: TACLXMLNode): TDLNAEntry; static;
  end;

  { TDLNAMusicLibraryExtension }

  TDLNAMusicLibraryExtension = class(TAIMPPropertyList,
    IAIMPMLDataProvider,
    IAIMPMLGroupingTreeDataProvider,
    IAIMPMLExtensionDataStorage,
    IUPnPDeviceFinderCallback)
  public const
    BackgroundTaskIdBase = 1000;
    FieldAlbum = 'Album';
    FieldAlbumArtist = 'AlbumArtist';
    FieldArtist = 'Artist';
    FieldGenre = 'Genre';
    FieldNodeUri = 'NodeUri';
    FieldTitle = 'Title';
    FieldYear = 'Year';
    NodeUriDelimiter = '|';
    StorageID = 'AIMP.DLNA.ML.Storage';
  strict private
    FDeviceFinder: TUPnPDeviceFinder;
    FDeviceFindTaskID: Integer;
    FDevices: TDictionary<WideString, IUPnPDevice>;
    FManager: IAIMPMLDataStorageManager;

    function Browse(const ADevice: IUPnPDevice; const ID: string;
      AFilter: TFunc<TACLXMLNode, Boolean> = nil): TList<TDLNAEntry>;
    procedure CancelFindDevices(const Sender: IUnknown);
    procedure FindDevices;
  protected
    // IAIMPPropertyList
    procedure DoGetValueAsInt32(PropertyID: Integer; out Value: Integer; var Result: HRESULT); override;
    function DoGetValueAsObject(PropertyID: Integer): IInterface; override;

    // IAIMPMLDataProvider
    function GetData(Fields: IAIMPObjectList; Filter: IAIMPMLDataFilter; out Data: IUnknown): HRESULT; overload; stdcall;

    // IAIMPMLGroupingTreeDataProvider
    function AppendFilter(Filter: IAIMPMLDataFilterGroup; Selection: IAIMPMLGroupingTreeSelection): HRESULT; stdcall;
    function GetCapabilities: DWORD; stdcall;
    function GetData(Selection: IAIMPMLGroupingTreeSelection; out Data: IAIMPMLGroupingTreeDataProviderSelection): HRESULT; overload; stdcall;
    function GetFieldForAlphabeticIndex(out FieldName: IAIMPString): HRESULT; stdcall;
    function ResolvePath(const S: string; out Device: IUPnPDevice; out SubPath: string): Boolean;

    // IAIMPMLExtensionDataStorage
    function ConfigLoad(Config: IAIMPConfig; Section: IAIMPString): HRESULT; stdcall;
    function ConfigSave(Config: IAIMPConfig; Section: IAIMPString): HRESULT; stdcall;
    function GetFields(Schema: Integer; out List: IAIMPObjectList): HRESULT; stdcall;
    function GetGroupingPresets(Schema: Integer; Presets: IAIMPMLGroupingPresets): HRESULT; stdcall;
    procedure FlushCache(AReserved: Integer); stdcall;
    procedure Finalize; stdcall;
    procedure Initialize(AManager: IAIMPMLDataStorageManager); stdcall;

    // IUPnPDeviceFinderCallback
    function DeviceAdded(lFindData: Integer; const pDevice: IUPnPDevice): HResult; stdcall;
    function DeviceRemoved(lFindData: Integer; const bstrUDN: WideString): HResult; stdcall;
    function SearchComplete(lFindData: Integer): HResult; stdcall;

    property Manager: IAIMPMLDataStorageManager read FManager;
  end;

implementation

type

  { TDLNAEnumerator }

  TDLNAEnumerator<T: IUnknown> = class
  strict private
    FCurrent: T;
    FEnum: IEnumVariant;
  public
    constructor Create(AEnum: IInterface);
    function GetEnumerator: TDLNAEnumerator<T>;
    function GetCurrent: T;
    function MoveNext: Boolean;
    property Current: T read GetCurrent;
  end;

  { TDLNAGroupingTreeFolder }

  TDLNAGroupingTreeFolder = class(TInterfacedObject, IAIMPMLGroupingTreeDataProviderSelection)
  strict private
    FChildren: TList<TDLNAEntry>;
    FDeviceUUID: string;
    FFieldName: IAIMPString;
    FIterator: Integer;
  public
    constructor Create(ADevice: IUPnPDevice; AChildren: TList<TDLNAEntry>);
    destructor Destroy; override;
    // IAIMPMLGroupingTreeDataProviderSelection
    function GetDisplayValue(out S: IAIMPString): HRESULT; stdcall;
    function GetFlags: Cardinal; stdcall;
    function GetImageIndex(out Index: Integer): HRESULT; stdcall;
    function GetValue(out FieldName: IAIMPString; out Value: OleVariant): HRESULT; stdcall;
    function NextRecord: LongBool; stdcall;
  end;

  { TDLNAGroupingTreeRoot }

  TDLNAGroupingTreeRoot = class(TInterfacedObject, IAIMPMLGroupingTreeDataProviderSelection)
  strict private
    FDevices: TArray<IUPnPDevice>;
    FFieldName: IAIMPString;
    FIterator: Integer;
  public
    constructor Create(ADevices: TArray<IUPnPDevice>);
    // IAIMPMLGroupingTreeDataProviderSelection
    function GetDisplayValue(out S: IAIMPString): HRESULT; stdcall;
    function GetFlags: Cardinal; stdcall;
    function GetImageIndex(out Index: Integer): HRESULT; stdcall;
    function GetValue(out FieldName: IAIMPString; out Value: OleVariant): HRESULT; stdcall;
    function NextRecord: LongBool; stdcall;
  end;

  { TDLNADataProvider }

  TDLNADataProvider = class(TInterfacedObjectEx, IAIMPMLDataProviderSelection)
  strict private
    FChildren: TList<TDLNAEntry>;
    FCurrent: TDLNAEntry;
    FFieldAlbum: Integer;
    FFieldAlbumArtist: Integer;
    FFieldArtist: Integer;
    FFieldDuration: Integer;
    FFieldFileName: Integer;
    FFieldGenre: Integer;
    FFieldNodeUri: Integer;
    FFieldSize: Integer;
    FFieldTitle: Integer;
    FFieldYear: Integer;
    FIterator: Integer;
    FNodeUri: string;
    FSupportedExts: string;
    FTempBuffer: string;
  protected
    function QueryInterface(const IID: TGUID; out Obj): HRESULT; override;
  public
    constructor Create(AFields: IAIMPObjectList; AChildren: TList<TDLNAEntry>; const ANodeUri: string);
    destructor Destroy; override;
    function GetValueAsFloat(FieldIndex: Integer): Double; stdcall;
    function GetValueAsInt32(FieldIndex: Integer): Integer; stdcall;
    function GetValueAsInt64(FieldIndex: Integer): Int64; stdcall;
    function GetValueAsString(FieldIndex: Integer): string; overload;
    function GetValueAsString(FieldIndex: Integer; out Length: Integer): PWideChar; overload; stdcall;
    function NextRow: LongBool; stdcall;
  end;

function EnumDataFieldFilters(const AFilter: IAIMPMLDataFilterGroup; AProc: TFunc<IAIMPMLDataFieldFilter, Boolean>): Boolean;
var
  AFieldFilter: IAIMPMLDataFieldFilter;
  AGroup: IAIMPMLDataFilterGroup;
begin
  Result := False;
  for var I := 0 to AFilter.GetChildCount - 1 do
  begin
    if Succeeded(AFilter.GetChild(I, IAIMPMLDataFilterGroup, AGroup)) then
      Result := EnumDataFieldFilters(AGroup, AProc)
    else
      if Succeeded(AFilter.GetChild(I, IAIMPMLDataFieldFilter, AFieldFilter)) then
        Result := AProc(AFieldFilter);

    if Result then
      Break;
  end;
end;

function GetFieldIndex(AFields: IAIMPObjectList; const AFieldName: string): Integer;
var
  AName: IAIMPString;
  AResult: Integer;
begin
  Result := -1;
  for var I := 0 to AFields.GetCount - 1 do
    if Succeeded(AFields.GetObject(I, IAIMPString, AName)) then
    begin
      if Succeeded(AName.Compare2(PChar(AFieldName), Length(AFieldName), AResult, False)) and (AResult = 0) then
        Exit(I);
    end;
end;

function GetSupportedExts: string;
var
  AService: IAIMPServiceFileFormats;
  AString: IAIMPString;
begin
  Result := '';
  if CoreGetService(IAIMPServiceFileFormats, AService) then
  begin
    if Succeeded(AService.GetFormats(AIMP_SERVICE_FILEFORMATS_CATEGORY_AUDIO, AString)) then
      Result := IAIMPStringToString(AString);
  end;
end;

{ TDLNAEntry }

class function TDLNAEntry.Create(ANode: TACLXMLNode): TDLNAEntry;
begin
  Result.ID := ANode.Attributes.GetValue('id');
  Result.Title := ANode.NodeValueByName('dc:title');
  Result.Album := ANode.NodeValueByName('upnp:album');
  Result.AlbumArtist := ANode.NodeValueByName('upnp:albumArtist');
  Result.Artist := ANode.NodeValueByName('upnp:artist');
  Result.Genre := ANode.NodeValueByName('upnp:genre');
  Result.Clazz := ANode.NodeValueByName('upnp:class');
  Result.Year := ANode.NodeValueByName('upnp:year');

  if ANode.FindNode('res', ANode) then
  begin
    Result.Url := ANode.NodeValue;
    Result.Size := ANode.Attributes.GetValueAsInt64('size');
    Result.Bitrate := ANode.Attributes.GetValueAsInteger('bitrate');
    TACLTimeFormat.Parse(ANode.Attributes.GetValue('duration'), Result.Duration);
  end;
end;

{ TDLNAMusicLibraryExtension }

procedure TDLNAMusicLibraryExtension.DoGetValueAsInt32(
  PropertyID: Integer; out Value: Integer; var Result: HRESULT);
begin
  if PropertyID = AIMPML_DATASTORAGE_PROPID_CAPABILITIES then
    Value := AIMPML_DATASTORAGE_CAP_PREIMAGES
  else
    inherited;
end;

function TDLNAMusicLibraryExtension.DoGetValueAsObject(PropertyID: Integer): IInterface;
begin
  case PropertyID of
    AIMPML_DATASTORAGE_PROPID_ID:
      Result := MakeString(StorageID);
    AIMPML_DATASTORAGE_PROPID_CAPTION:
      Result := MakeString('DLNA');
  else
    Result := inherited DoGetValueAsObject(PropertyID);
  end;
end;

function TDLNAMusicLibraryExtension.GetData(
  Fields: IAIMPObjectList; Filter: IAIMPMLDataFilter; out Data: IInterface): HRESULT;
var
  AChildren: TList<TDLNAEntry>;
  ADevice: IUPnPDevice;
  ANodeUri: IAIMPString;
  ASubPath: string;
begin
  Result := S_OK;
  try
    Data := nil;

    ANodeUri := nil;
    if EnumDataFieldFilters(Filter,
      function (AFilter: IAIMPMLDataFieldFilter): Boolean
      var
        AField: IAIMPMLDataField;
      begin
        Result :=
          (AFilter.GetValueAsObject(AIMPML_FIELDFILTER_FIELD, IAIMPMLDataField, AField) = 0) and
          (PropListGetStr(AField, AIMPML_FIELD_PROPID_NAME) = FieldNodeUri) and
          (PropListGetStr(AFilter, AIMPML_FIELDFILTER_VALUE1, ANodeUri));
      end)
    then
      if ResolvePath(IAIMPStringToString(ANodeUri), ADevice, ASubPath) then
      begin
        AChildren := Browse(ADevice, ASubPath,
          function (ANode: TACLXMLNode): Boolean
          begin
            Result := ANode.NodeName = 'item';
          end);
        if AChildren <> nil then
        begin
          Data := TDLNADataProvider.Create(Fields, AChildren, IAIMPStringToString(ANodeUri));
          Result := S_OK;
        end;
      end;
  except
    on E: Exception do
      Data := MakeString(E.Message);
  end;
end;

function TDLNAMusicLibraryExtension.AppendFilter(
  Filter: IAIMPMLDataFilterGroup; Selection: IAIMPMLGroupingTreeSelection): HRESULT; stdcall;
var
  AFieldName: IAIMPString;
  AFilter: IAIMPMLDataFieldFilter;
  AValue: OleVariant;
begin
  Filter.BeginUpdate;
  try
    Filter.SetValueAsInt32(AIMPML_FILTERGROUP_OPERATION, AIMPML_FILTERGROUP_OPERATION_AND);
    for var I := 0 to Selection.GetCount - 1 do
    begin
      if Succeeded(Selection.GetValue(I, AFieldName, AValue)) then
        Filter.Add(AFieldName, AValue, Null, AIMPML_FIELDFILTER_OPERATION_EQUALS, AFilter);
    end;
  finally
    Filter.EndUpdate;
  end;
  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.GetCapabilities: DWORD; stdcall;
begin
  Result := AIMPML_GROUPINGTREEDATAPROVIDER_CAP_HIDEALLDATA;
end;

function TDLNAMusicLibraryExtension.GetData(Selection: IAIMPMLGroupingTreeSelection;
  out Data: IAIMPMLGroupingTreeDataProviderSelection): HRESULT; stdcall;
var
  AChildren: TList<TDLNAEntry>;
  ADevice: IUPnPDevice;
  AFieldName: IAIMPString;
  ASubPath: string;
  AValue: OleVariant;
begin
  Result := E_FAIL;
  if Succeeded(Selection.GetValue(0, AFieldName, AValue)) then
  begin
    if not acSameText(IAIMPStringToString(AFieldName), FieldNodeUri) then
      Exit(E_UNEXPECTED);
  end
  else
    AValue := '';

  if AValue <> '' then
  begin
    if ResolvePath(AValue, ADevice, ASubPath) then
    begin
      AChildren := Browse(ADevice, ASubPath,
        function (ANode: TACLXMLNode): Boolean
        begin
          Result := ANode.NodeName = 'container'
        end);
      if AChildren <> nil then
      begin
        Data := TDLNAGroupingTreeFolder.Create(ADevice, AChildren);
        Result := S_OK;
      end;
    end;
  end
  else
    if FDevices.Count > 0 then
    begin
      Data := TDLNAGroupingTreeRoot.Create(FDevices.Values.ToArray);
      Result := S_OK;
    end;
end;

function TDLNAMusicLibraryExtension.GetFieldForAlphabeticIndex(out FieldName: IAIMPString): HRESULT; stdcall;
begin
  Result := E_FAIL;
end;

function TDLNAMusicLibraryExtension.Browse(const ADevice: IUPnPDevice;
  const ID: string; AFilter: TFunc<TACLXMLNode, Boolean>): TList<TDLNAEntry>;

  function GetContentDirectoryService: IUPnPService;
  begin
    if not IsMainThread then
      CoInitialize(nil);
    for var Service in TDLNAEnumerator<IUPnPService>.Create(ADevice.Services._NewEnum) do
    begin
      if Service.ServiceTypeIdentifier = 'urn:schemas-upnp-org:service:ContentDirectory:1' then
        Exit(Service);
    end;
    Result := nil;
  end;

var
  ADoc: TACLXMLDocument;
  ANode: TACLXMLNode;
  AParamsIn: OleVariant;
  AParamsOut: OleVariant;
  AService: IUPnPService;
begin
  Result := nil;

  {$MESSAGE 'TODO - cache requests'}
  AService := GetContentDirectoryService;
  if AService <> nil then
  try
    AParamsIn := VarArrayCreate([0, 5], varVariant);
    AParamsIn[0] := IfThenW(ID, '0');
    AParamsIn[1] := 'BrowseDirectChildren';
    AParamsIn[2] := '';
    AParamsIn[3] := 0;
    AParamsIn[4] := 0;
    AParamsIn[5] := '';

    AParamsOut := VarArrayCreate([0, 0], varVariant);
    AService.InvokeAction('Browse', AParamsIn, AParamsOut);

    ADoc := TACLXMLDocument.Create;
    try
      ADoc.LoadFromString(acEncodeUTF8(AParamsOut[0]));
      if ADoc.Count > 0 then
        for var I := 0 to ADoc.Nodes[0].Count - 1 do
        begin
          ANode := ADoc.Nodes[0][I];
          if not Assigned(AFilter) or AFilter(ANode) then
          begin
            if Result = nil then
              Result := TList<TDLNAEntry>.Create;
            Result.Add(TDLNAEntry.Create(ANode));
          end;
        end;
    finally
      ADoc.Free;
    end;
  except
    // do nothing
  end;
end;

procedure TDLNAMusicLibraryExtension.CancelFindDevices(const Sender: IInterface);
begin
  if FDeviceFindTaskID <> 0 then
    FDeviceFinder.CancelAsyncFind(FDeviceFindTaskID);
end;

function TDLNAMusicLibraryExtension.ConfigLoad(Config: IAIMPConfig; Section: IAIMPString): HRESULT;
begin
  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.ConfigSave(Config: IAIMPConfig; Section: IAIMPString): HRESULT;
begin
  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.GetFields(Schema: Integer; out List: IAIMPObjectList): HRESULT;

  function CreateField(const AName: string; AType, AFlags: Integer): IAIMPMLDataField;
  begin
    CoreCreateObject(IAIMPMLDataField, Result);
    CheckResult(Result.SetValueAsInt32(AIMPML_FIELD_PROPID_TYPE, AType));
    CheckResult(Result.SetValueAsInt32(AIMPML_FIELD_PROPID_FLAGS, AFlags));
    CheckResult(Result.SetValueAsObject(AIMPML_FIELD_PROPID_NAME, MakeString(AName)));
  end;

begin
  CoreCreateObject(IAIMPObjectList, List);
  case Schema of
    AIMPML_FIELDS_SCHEMA_ALL:
      begin
        List.Add(CreateField(AIMPML_RESERVED_FIELD_ID, AIMPML_FIELDTYPE_STRING, AIMPML_FIELDFLAG_INTERNAL));
        List.Add(CreateField(AIMPML_RESERVED_FIELD_FILENAME, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(AIMPML_RESERVED_FIELD_DURATION, AIMPML_FIELDTYPE_DURATION, 0));
        List.Add(CreateField(AIMPML_RESERVED_FIELD_FILESIZE, AIMPML_FIELDTYPE_FILESIZE, 0));
        List.Add(CreateField(FieldArtist, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldAlbum, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldAlbumArtist, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldTitle, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldGenre, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldYear, AIMPML_FIELDTYPE_STRING, 0));
        List.Add(CreateField(FieldNodeUri, AIMPML_FIELDTYPE_STRING, AIMPML_FIELDFLAG_INTERNAL));
      end;

    AIMPML_FIELDS_SCHEMA_TABLE_GROUPBY,
    AIMPML_FIELDS_SCHEMA_TABLE_GROUPDETAILS:
      begin
        List.Add(MakeString(FieldArtist));
        List.Add(MakeString(FieldAlbum));
      end;

    AIMPML_FIELDS_SCHEMA_TABLE_VIEW_ALBUMTHUMBNAILS,
    AIMPML_FIELDS_SCHEMA_TABLE_VIEW_DEFAULT,
    AIMPML_FIELDS_SCHEMA_TABLE_VIEW_GROUPDETAILS:
      begin
        List.Add(MakeString(FieldTitle));
        List.Add(MakeString(FieldArtist));
        List.Add(MakeString(FieldAlbum));
        List.Add(MakeString(AIMPML_RESERVED_FIELD_DURATION));
      end;
  end;

  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.GetGroupingPresets(
  Schema: Integer; Presets: IAIMPMLGroupingPresets): HRESULT;
var
  APreset: IAIMPMLGroupingPreset;
begin
  Result := S_OK;
  if Schema = AIMPML_GROUPINGPRESETS_SCHEMA_BUILTIN then
    Presets.Add(nil, LangLoadStringEx('MSG\35'), 0, Self, APreset);
end;

procedure TDLNAMusicLibraryExtension.FlushCache(AReserved: Integer);
begin
  FDevices.Clear;
  FindDevices;
end;

procedure TDLNAMusicLibraryExtension.Finalize;
begin
  if FDeviceFindTaskID <> 0 then
    FDeviceFinder.CancelAsyncFind(FDeviceFindTaskID);
  FreeAndNil(FDeviceFinder);
  FreeAndNil(FDevices);
  FManager := nil;
end;

procedure TDLNAMusicLibraryExtension.FindDevices;
begin
  if FDeviceFindTaskID = 0 then
  begin
    FDeviceFindTaskID := FDeviceFinder.CreateAsyncFind('urn:schemas-upnp-org:device:MediaServer:1', 0, Self);
    TACLMainThread.RunImmediately(
      procedure
      begin
        if FManager <> nil then
          FManager.BackgroundTaskStarted(
            BackgroundTaskIdBase + FDeviceFindTaskId, LangLoadStringEx('MSG\67'),
            TAIMPUINotifyEventAdapter.Create(CancelFindDevices));
      end);
    FDeviceFinder.StartAsyncFind(FDeviceFindTaskID);
  end;
end;

procedure TDLNAMusicLibraryExtension.Initialize(AManager: IAIMPMLDataStorageManager);
begin
  FManager := AManager;
  FDevices := TDictionary<WideString, IUPnPDevice>.Create;
  FDeviceFinder := TUPnPDeviceFinder.Create(nil);
  FindDevices;
end;

function TDLNAMusicLibraryExtension.ResolvePath(const S: string; out Device: IUPnPDevice; out SubPath: string): Boolean;
var
  ADelimPos: Integer;
begin
  if S = '' then
    Exit(False);

  ADelimPos := acPos(NodeUriDelimiter, S);
  if ADelimPos > 0 then
  begin
    SubPath := Copy(S, ADelimPos + Length(NodeUriDelimiter));
    Result := FDevices.TryGetValue(Copy(S, 1, ADelimPos - 1), Device);
  end
  else
    Result := FDevices.TryGetValue(S, Device);
end;

function TDLNAMusicLibraryExtension.DeviceAdded(lFindData: Integer; const pDevice: IUPnPDevice): HResult; stdcall;
begin
  FDevices.AddOrSetValue(pDevice.UniqueDeviceName, pDevice);
  TACLMainThread.RunImmediately(
    procedure
    begin
      if FManager <> nil then
        FManager.Changed;
    end);
  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.DeviceRemoved(lFindData: Integer; const bstrUDN: WideString): HResult; stdcall;
begin
  FDevices.Remove(bstrUDN);
  Result := S_OK;
end;

function TDLNAMusicLibraryExtension.SearchComplete(lFindData: Integer): HResult; stdcall;
begin
  TACLMainThread.RunImmediately(
    procedure
    begin
      if FManager <> nil then
        FManager.BackgroundTaskFinished(BackgroundTaskIdBase + FDeviceFindTaskID);
      FDeviceFindTaskID := 0;
    end);
  Result := S_OK;
end;

{ TDLNAEnumerator }

constructor TDLNAEnumerator<T>.Create(AEnum: IInterface);
begin
  if not Supports(AEnum, IEnumVariant, FEnum) then
    FEnum := nil;
end;

function TDLNAEnumerator<T>.GetCurrent: T;
begin
  Result := FCurrent;
end;

function TDLNAEnumerator<T>.GetEnumerator: TDLNAEnumerator<T>;
begin
  Result := Self;
end;

function TDLNAEnumerator<T>.MoveNext: Boolean;
var
  AOleCurrent: OleVariant;
  AFetched: Cardinal;
begin
  Result := (FEnum <> nil) and Succeeded(FEnum.Next(1, AOleCurrent, AFetched)) and (AFetched = 1) and
    Succeeded(acGetInterfaceEx(AOleCurrent, TACLInterfaceHelper<T>.GetGuid, FCurrent));
end;

{ TDLNAGroupingTreeFolder }

constructor TDLNAGroupingTreeFolder.Create(ADevice: IUPnPDevice; AChildren: TList<TDLNAEntry>);
begin
  FChildren := AChildren;
  FDeviceUUID := ADevice.UniqueDeviceName;
  FFieldName := MakeString(TDLNAMusicLibraryExtension.FieldNodeUri);
end;

destructor TDLNAGroupingTreeFolder.Destroy;
begin
  FreeAndNil(FChildren);
  inherited;
end;

function TDLNAGroupingTreeFolder.GetDisplayValue(out S: IAIMPString): HRESULT;
begin
  S := MakeString(FChildren[FIterator].Title);
  Result := S_OK;
end;

function TDLNAGroupingTreeFolder.GetFlags: Cardinal;
begin
  Result := AIMPML_GROUPINGTREENODE_FLAG_STANDALONE or AIMPML_GROUPINGTREENODE_FLAG_HASCHILDREN;
end;

function TDLNAGroupingTreeFolder.GetImageIndex(out Index: Integer): HRESULT;
begin
  Index := AIMPML_FIELDIMAGE_FOLDER;
  Result := S_OK;
end;

function TDLNAGroupingTreeFolder.GetValue(out FieldName: IAIMPString; out Value: OleVariant): HRESULT;
begin
  FieldName := FFieldName;
  Value := FDeviceUUID + TDLNAMusicLibraryExtension.NodeUriDelimiter + FChildren[FIterator].ID;
  Result := S_OK;
end;

function TDLNAGroupingTreeFolder.NextRecord: LongBool;
begin
  Inc(FIterator);
  Result := FIterator < FChildren.Count;
end;

{ TDLNAGroupingTreeRoot }

constructor TDLNAGroupingTreeRoot.Create(ADevices: TArray<IUPnPDevice>);
begin
  FDevices := ADevices;
  FFieldName := MakeString(TDLNAMusicLibraryExtension.FieldNodeUri);
end;

function TDLNAGroupingTreeRoot.GetDisplayValue(out S: IAIMPString): HRESULT;
begin
  try
    S := MakeString(FDevices[FIterator].FriendlyName);
    Result := S_OK;
  except
    Result := E_UNEXPECTED;
  end;
end;

function TDLNAGroupingTreeRoot.GetFlags: Cardinal;
begin
  Result := AIMPML_GROUPINGTREENODE_FLAG_STANDALONE or AIMPML_GROUPINGTREENODE_FLAG_HASCHILDREN;
end;

function TDLNAGroupingTreeRoot.GetImageIndex(out Index: Integer): HRESULT;
begin
  Index := AIMPML_FIELDIMAGE_NOTE;
  Result := S_OK;
end;

function TDLNAGroupingTreeRoot.GetValue(out FieldName: IAIMPString; out Value: OleVariant): HRESULT;
begin
  FieldName := FFieldName;
  Value := FDevices[FIterator].UniqueDeviceName;
  Result := S_OK;
end;

function TDLNAGroupingTreeRoot.NextRecord: LongBool;
begin
  Inc(FIterator);
  Result := FIterator < Length(FDevices);
end;

{ TDLNADataProvider }

constructor TDLNADataProvider.Create(AFields: IAIMPObjectList; AChildren: TList<TDLNAEntry>; const ANodeUri: string);
begin
  FNodeUri := ANodeUri;
  FChildren := AChildren;
  FSupportedExts := GetSupportedExts;
  FFieldAlbum := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldAlbum);
  FFieldAlbumArtist := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldAlbumArtist);
  FFieldArtist := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldArtist);
  FFieldGenre := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldGenre);
  FFieldTitle := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldTitle);
  FFieldYear := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldYear);
  FFieldSize := GetFieldIndex(AFields, AIMPML_RESERVED_FIELD_FILESIZE);
  FFieldFileName := GetFieldIndex(AFields, AIMPML_RESERVED_FIELD_FILENAME);
  FFieldDuration := GetFieldIndex(AFields, AIMPML_RESERVED_FIELD_DURATION);
  FFieldNodeUri := GetFieldIndex(AFields, TDLNAMusicLibraryExtension.FieldNodeUri);

  FIterator := -1;
  NextRow;
end;

destructor TDLNADataProvider.Destroy;
begin
  FreeAndNil(FChildren);
  inherited;
end;

function TDLNADataProvider.GetValueAsFloat(FieldIndex: Integer): Double;
begin
  if FieldIndex = FFieldDuration then
    Result := FCurrent.Duration
  else
    Result := 0;
end;

function TDLNADataProvider.GetValueAsInt32(FieldIndex: Integer): Integer;
begin
  Result := 0;
end;

function TDLNADataProvider.GetValueAsInt64(FieldIndex: Integer): Int64;
begin
  if FieldIndex = FFieldSize then
    Result := FCurrent.Size
  else
    Result := 0;
end;

function TDLNADataProvider.GetValueAsString(FieldIndex: Integer): string;
begin
  if FieldIndex = FFieldAlbum then
    Result := FCurrent.Album
  else if FieldIndex = FFieldAlbumArtist then
    Result := FCurrent.AlbumArtist
  else if FieldIndex = FFieldArtist then
    Result := FCurrent.Artist
  else if FieldIndex = FFieldFileName then
    Result := FCurrent.Url
  else if FieldIndex = FFieldGenre then
    Result := FCurrent.Genre
  else if FieldIndex = FFieldTitle then
    Result := FCurrent.Title
  else if FieldIndex = FFieldNodeUri then
    Result := FNodeUri
  else if FieldIndex = FFieldYear then
    Result := FCurrent.Year
  else
    Result := '';
end;

function TDLNADataProvider.GetValueAsString(FieldIndex: Integer; out Length: Integer): PWideChar;
begin
  FTempBuffer := GetValueAsString(FieldIndex);
  Length := System.Length(FTempBuffer);
  Result := PWideChar(FTempBuffer);
end;

function TDLNADataProvider.NextRow: LongBool;
begin
  Result := True;
  repeat
    Inc(FIterator);
    if FIterator >= FChildren.Count then
      Exit(False);
    FCurrent := FChildren[FIterator];
  until acIsOurFile(FSupportedExts, FCurrent.Url);
end;

function TDLNADataProvider.QueryInterface(const IID: TGUID; out Obj): HRESULT;
begin
  if (IID = IID_IAIMPMLDataProviderSelection) and (FIterator >= FChildren.Count) then
    Result := E_NOINTERFACE
  else
    Result := inherited QueryInterface(IID, Obj);
end;

end.
