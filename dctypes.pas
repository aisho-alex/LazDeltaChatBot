unit dctypes;

{$mode objfpc}{$H+}

interface

type
  TAccountId = UInt64;
  TChatId    = UInt64;
  TMsgId     = UInt64;
  TContactId = UInt64;

const
  ContactSelf        = 1;
  ContactInfo       = 2;
  ContactDevice     = 5;
  ContactLastSpecial= 9;

type
  // Snapshot of a message – only fields we need.
  // The attachment fields mirror the deltachat-rpc-server Message object:
  //   file / fileName / fileMime / fileBytes / viewType / downloadState
  TMsgSnapshot = record
    Id            : TMsgId;
    ChatId        : TChatId;
    FromId        : TContactId;
    Text          : string;
    IsBot         : Boolean;
    IsInfo        : Boolean;
    // --- attachments -------------------------------------------------
    FilePath      : string;  // local path of the file, '' if none/not downloaded
    FileName      : string;  // original name, e.g. photo.jpg
    FileMime      : string;  // e.g. image/jpeg
    FileBytes     : Int64;   // size in bytes
    ViewType      : string;  // text / image / video / audio / file / ...
    DownloadState : string;  // done / available / inProgress / failure / notDownloaded
  end;

{ True when the message carries an attachment. }
function MsgHasAttachment(const S: TMsgSnapshot): Boolean;

implementation

function MsgHasAttachment(const S: TMsgSnapshot): Boolean;
begin
  Result := (S.FilePath <> '') or (S.FileName <> '') or (S.FileBytes > 0);
end;

end.
