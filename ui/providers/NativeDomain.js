.pragma library

// Generated from Rust providers::domain::snapshot; parity is verified by Rust tests.
var FACTS = {
  "gmail": {
    "addressSearch": true,
    "capabilities": {
      "archive": true,
      "batch": true,
      "conversations": false,
      "labels": true,
      "manageLabels": true,
      "move": true,
      "search": true,
      "send": true,
      "spam": true,
      "star": true,
      "threads": true,
      "web": true,
      "webBox": true
    },
    "inheritedDefault": "in:inbox",
    "nativeSync": true,
    "queries": {
      "all": "in:anywhere -in:spam -in:trash",
      "drafts": "in:drafts",
      "inbox": "in:inbox",
      "sent": "in:sent",
      "spam": "in:spam",
      "starred": "is:starred",
      "trash": "in:trash",
      "unread": "in:inbox is:unread -category:promotions -category:social -category:forums"
    },
    "searchOperators": [
      {
        "description": "Messages from a sender",
        "example": "from:ada@example.org",
        "operator": "from",
        "primary": true,
        "values": [
          "me"
        ]
      },
      {
        "description": "Messages sent to a recipient",
        "example": "to:me",
        "operator": "to",
        "primary": true,
        "values": [
          "me"
        ]
      },
      {
        "description": "Words in the subject",
        "example": "subject:invoice",
        "operator": "subject",
        "primary": true,
        "values": []
      },
      {
        "description": "Read, unread, starred or important messages",
        "example": "is:unread",
        "operator": "is",
        "primary": true,
        "values": [
          "read",
          "unread",
          "starred",
          "important"
        ]
      },
      {
        "description": "Messages with a label",
        "example": "label:\"Work projects\"",
        "operator": "label",
        "primary": true,
        "values": []
      },
      {
        "description": "Messages in a folder",
        "example": "in:inbox",
        "operator": "in",
        "primary": true,
        "values": [
          "inbox",
          "sent",
          "drafts",
          "spam",
          "trash",
          "anywhere"
        ]
      },
      {
        "description": "Messages with file attachments",
        "example": "has:attachment",
        "operator": "has",
        "primary": true,
        "values": [
          "attachment"
        ]
      },
      {
        "description": "An attachment name or file type",
        "example": "filename:pdf",
        "operator": "filename",
        "primary": true,
        "values": []
      },
      {
        "description": "Messages after a date in Pacific Standard Time",
        "example": "after:2026/10/01",
        "operator": "after",
        "primary": true,
        "values": []
      },
      {
        "description": "Messages before a date in Pacific Standard Time",
        "example": "before:2026/11/01",
        "operator": "before",
        "primary": true,
        "values": []
      },
      {
        "description": "Messages newer than days, months or years",
        "example": "newer_than:7d",
        "operator": "newer_than",
        "primary": false,
        "values": []
      },
      {
        "description": "Messages older than days, months or years",
        "example": "older_than:1y",
        "operator": "older_than",
        "primary": false,
        "values": []
      }
    ],
    "searchSyntax": "gmail",
    "webHomeUrl": "https://mail.google.com/mail/u/0/"
  }
}
