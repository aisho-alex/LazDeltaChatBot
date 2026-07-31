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
  // Snapshot of a message – only fields we need
  TMsgSnapshot = record
    Id     : TMsgId;
    ChatId : TChatId;
    FromId : TContactId;
    Text   : string;
    IsBot  : Boolean;
    IsInfo : Boolean;
  end;

implementation

end.
