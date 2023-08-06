import { expect, test } from "vitest";

import { transform } from "../src/";

const googleEvent = {
  id: "61h3gp1pcpj36b9oc8p6cb9k6cp38bb2c5imabb56gq3gc1h68omap1n70",
  data: {
    attendees: [
      {
        displayName: "Steven Lu",
        email: "steven@mangoprotection.com",
        responseStatus: "accepted",
      },
      {
        email: "kris@plot.day",
        organizer: true,
        responseStatus: "accepted",
        self: true,
      },
    ],
    conferenceData: {
      conferenceId: "jub-pktq-snb",
      conferenceSolution: {
        iconUri:
          "https://fonts.gstatic.com/s/i/productlogos/meet_2020q4/v6/web-512dp/logo_meet_2020q4_color_2x_web_512dp.png",
        key: {
          type: "hangoutsMeet",
        },
        name: "Google Meet",
      },
      createRequest: {
        conferenceSolutionKey: {
          type: "hangoutsMeet",
        },
        requestId: "6oq38eb56os30b9k68omab9k6pi6ab9o75i3ibb161gj6p1kcooj0oho6c",
        status: {
          statusCode: "success",
        },
      },
      entryPoints: [
        {
          entryPointType: "video",
          label: "meet.google.com/jub-pktq-snb",
          uri: "https://meet.google.com/jub-pktq-snb",
        },
        {
          entryPointType: "more",
          pin: "3759000765575",
          uri: "https://tel.meet/jub-pktq-snb?pin=3759000765575",
        },
        {
          entryPointType: "phone",
          label: "+1 604-774-9252",
          pin: "854422432",
          regionCode: "CA",
          uri: "tel:+1-604-774-9252",
        },
      ],
    },
    created: "2022-03-08T03:13:06.000Z",
    creator: {
      email: "kris@plot.day",
      self: true,
    },
    end: {
      dateTime: "2022-03-08T20:30:00-05:00",
      timeZone: "America/Toronto",
    },
    etag: '"3293419594100000"',
    eventType: "default",
    hangoutLink: "https://meet.google.com/jub-pktq-snb",
    htmlLink:
      "https://www.google.com/calendar/event?eid=NjFoM2dwMXBjcGozNmI5b2M4cDZjYjlrNmNwMzhiYjJjNWltYWJiNTZncTNnYzFoNjhvbWFwMW43MCBrcmlzQHBsb3QuZGF5",
    iCalUID:
      "61h3gp1pcpj36b9oc8p6cb9k6cp38bb2c5imabb56gq3gc1h68omap1n70@google.com",
    id: "61h3gp1pcpj36b9oc8p6cb9k6cp38bb2c5imabb56gq3gc1h68omap1n70",
    kind: "calendar#event",
    organizer: {
      email: "kris@plot.day",
      self: true,
    },
    reminders: {
      useDefault: true,
    },
    sequence: 0,
    start: {
      dateTime: "2022-03-08T20:00:00-05:00",
      timeZone: "America/Toronto",
    },
    status: "confirmed",
    summary: "Stephen <> Kris",
    updated: "2022-03-08T03:23:17.050Z",
  },
};

const outlookEvent = {
  id: "AAMkADM3Mzg2YzNmLTVlNDktNGRkYS04YWI5LWJiN2Q2OTQxNWU5ZgFRAAgI2-Rb9W-AAEYAAAAAjio57DPmlUGXdwcURzCFIwcALZDz2w6YfkW5DI83zWMP0gAAAAABDQAALZDz2w6YfkW5DI83zWMP0gAADMVoHgAAEA==",
  data: {
    "@odata.etag": 'W/"DwAAABYAAAAtkPPbDph+RbkMjzfNYw/SAAAMxVut"',
    "@odata.type": "#microsoft.graph.event",
    allowNewTimeProposals: true,
    attendees: [
      {
        emailAddress: {
          address: "PradeepG@wvcrw.onmicrosoft.com",
          name: "Pradeep Gupta",
        },
        status: {
          response: "none",
          time: "0001-01-01T00:00:00Z",
        },
        type: "required",
      },
    ],
    body: {
      content:
        '<html>\r\n<head>\r\n<meta http-equiv="Content-Type" content="text/html; charset=utf-8">\r\n</head>\r\n<body>\r\n<div class="elementToProof" style="font-family:Calibri,Arial,Helvetica,sans-serif; font-size:12pt; color:rgb(0,0,0)">\r\nRooster says &quot;wake up!&quot;</div>\r\n<br>\r\n<div style="width:100%"><span style="white-space:nowrap; color:#5F5F5F; opacity:.36">________________________________________________________________________________</span>\r\n</div>\r\n<div class="me-email-text" lang="en-US" style="color:#252424; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">\r\n<div style="margin-top:24px; margin-bottom:20px"><span style="font-size:24px; color:#252424">Microsoft Teams meeting</span>\r\n</div>\r\n<div style="margin-bottom:20px">\r\n<div style="margin-top:0px; margin-bottom:0px; font-weight:bold"><span style="font-size:14px; color:#252424">Join on your computer, mobile app or room device</span>\r\n</div>\r\n<a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_MzBmYzAxYjktNDBlZS00MGIzLTg1MzktYThlYzQ0ODZjNDU2%40thread.v2/0?context=%7b%22Tid%22%3a%22906d1680-c46e-4105-9c77-5bc90110a6e6%22%2c%22Oid%22%3a%2239353b6b-e313-4c06-9f2d-ebd5ca2c9190%22%7d" class="me-email-headline" style="font-size:14px; font-family:\'Segoe UI Semibold\',\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif; text-decoration:underline; color:#6264a7">Click\r\n here to join the meeting</a> </div>\r\n<div style="margin-bottom:20px; margin-top:20px">\r\n<div style="margin-bottom:4px"><span data-tid="meeting-code" style="font-size:14px; color:#252424">Meeting ID:\r\n<span style="font-size:16px; color:#252424">213 050 950 66</span> </span><br>\r\n<span style="font-size:14px; color:#252424">Passcode: </span><span style="font-size:16px; color:#252424">BuLHJx\r\n</span>\r\n<div style="font-size:14px"><a href="https://www.microsoft.com/en-us/microsoft-teams/download-app" class="me-email-link" style="font-size:14px; text-decoration:underline; color:#6264a7; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">Download\r\n Teams</a> | <a href="https://www.microsoft.com/microsoft-teams/join-a-meeting" class="me-email-link" style="font-size:14px; text-decoration:underline; color:#6264a7; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">\r\nJoin on the web</a></div>\r\n</div>\r\n</div>\r\n<div style="margin-bottom:24px; margin-top:20px"><a href="https://aka.ms/JoinTeamsMeeting" class="me-email-link" style="font-size:14px; text-decoration:underline; color:#6264a7; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">Learn More</a>\r\n | <a href="https://teams.microsoft.com/meetingOptions/?organizerId=39353b6b-e313-4c06-9f2d-ebd5ca2c9190&amp;tenantId=906d1680-c46e-4105-9c77-5bc90110a6e6&amp;threadId=19_meeting_MzBmYzAxYjktNDBlZS00MGIzLTg1MzktYThlYzQ0ODZjNDU2@thread.v2&amp;messageId=0&amp;language=en-US" class="me-email-link" style="font-size:14px; text-decoration:underline; color:#6264a7; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">\r\nMeeting options</a> </div>\r\n</div>\r\n<div style="font-size:14px; margin-bottom:4px; font-family:\'Segoe UI\',\'Helvetica Neue\',Helvetica,Arial,sans-serif">\r\n</div>\r\n<div style="font-size:12px"></div>\r\n<div></div>\r\n<div style="width:100%"><span style="white-space:nowrap; color:#5F5F5F; opacity:.36">________________________________________________________________________________</span>\r\n</div>\r\n</body>\r\n</html>\r\n',
      contentType: "html",
    },
    bodyPreview:
      'Rooster says "wake up!"\r\n\r\n________________________________________________________________________________\r\nMicrosoft Teams meeting\r\nJoin on your computer, mobile app or room device\r\nClick here to join the meeting\r\nMeeting ID: 213 050 950 66\r\nPasscode: B',
    categories: [],
    changeKey: "LZDz2w6YfkW5DI83zWMP0gAADMVbrQ==",
    createdDateTime: "2023-07-25T21:04:25.7133801Z",
    end: {
      dateTime: "2023-12-04T12:30:00.0000000",
      timeZone: "UTC",
    },
    hasAttachments: false,
    hideAttendees: false,
    iCalUId:
      "040000008200E00074C5B7101A82E008000000005313EE973BBFD901000000000000000010000000812DAF9A343C374EB06B5FD97BB0B423",
    id: "AAMkADM3Mzg2YzNmLTVlNDktNGRkYS04YWI5LWJiN2Q2OTQxNWU5ZgFRAAgI2-Rb9W-AAEYAAAAAjio57DPmlUGXdwcURzCFIwcALZDz2w6YfkW5DI83zWMP0gAAAAABDQAALZDz2w6YfkW5DI83zWMP0gAADMVoHgAAEA==",
    importance: "normal",
    isAllDay: false,
    isCancelled: false,
    isDraft: false,
    isOnlineMeeting: true,
    isOrganizer: true,
    isReminderOn: true,
    lastModifiedDateTime: "2023-07-25T21:04:45.1558529Z",
    location: {
      displayName: "Microsoft Teams Meeting",
      locationType: "default",
      uniqueId: "Microsoft Teams Meeting",
      uniqueIdType: "private",
    },
    locations: [
      {
        displayName: "Microsoft Teams Meeting",
        locationType: "default",
        uniqueId: "Microsoft Teams Meeting",
        uniqueIdType: "private",
      },
    ],
    occurrenceId: null,
    onlineMeeting: {
      joinUrl:
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_MzBmYzAxYjktNDBlZS00MGIzLTg1MzktYThlYzQ0ODZjNDU2%40thread.v2/0?context=%7b%22Tid%22%3a%22906d1680-c46e-4105-9c77-5bc90110a6e6%22%2c%22Oid%22%3a%2239353b6b-e313-4c06-9f2d-ebd5ca2c9190%22%7d",
    },
    onlineMeetingProvider: "teamsForBusiness",
    onlineMeetingUrl: null,
    organizer: {
      emailAddress: {
        address: "AdeleV@wvcrw.onmicrosoft.com",
        name: "Adele Vance",
      },
    },
    originalEndTimeZone: "Eastern Standard Time",
    originalStartTimeZone: "Eastern Standard Time",
    recurrence: {
      pattern: {
        dayOfMonth: 0,
        daysOfWeek: ["monday", "tuesday", "wednesday", "thursday", "friday"],
        firstDayOfWeek: "sunday",
        index: "first",
        interval: 1,
        month: 0,
        type: "weekly",
      },
      range: {
        endDate: "2023-12-04",
        numberOfOccurrences: 0,
        recurrenceTimeZone: "Eastern Standard Time",
        startDate: "2023-09-04",
        type: "endDate",
      },
    },
    reminderMinutesBeforeStart: 15,
    responseRequested: true,
    responseStatus: {
      response: "organizer",
      time: "0001-01-01T00:00:00Z",
    },
    sensitivity: "normal",
    seriesMasterId:
      "AAMkADM3Mzg2YzNmLTVlNDktNGRkYS04YWI5LWJiN2Q2OTQxNWU5ZgBGAAAAAACOKjnsM_aVQZd3BxRHMIUjBwAtkPPbDph_RbkMjzfNYw-SAAAAAAENAAAtkPPbDph_RbkMjzfNYw-SAAAMxWgeAAA=",
    showAs: "busy",
    start: {
      dateTime: "2023-12-04T12:00:00.0000000",
      timeZone: "UTC",
    },
    subject: "Cockadoodledoo",
    transactionId: "18ed331c-ddc9-4f60-3240-dba7177b11e5",
    type: "occurrence",
    webLink:
      "https://outlook.office365.com/owa/?itemid=AAMkADM3Mzg2YzNmLTVlNDktNGRkYS04YWI5LWJiN2Q2OTQxNWU5ZgBGAAAAAACOKjnsM%2BaVQZd3BxRHMIUjBwAtkPPbDph%2BRbkMjzfNYw%2FSAAAAAAENAAAtkPPbDph%2BRbkMjzfNYw%2FSAAAMxWgeAAA%3D&exvsurl=1&path=/calendar/item",
  },
};

test("transforms Google events", async () => {
  const event = transform("google", googleEvent);
  expect(event.name).eq("Stephen <> Kris");
  expect(event.invitees.length).eq(2);
  expect(event.availability).eq("busy");
  expect(event.visibility).eq("normal");
});

test("transforms Outlook events", async () => {
  const event = transform("outlook", outlookEvent);
  expect(event.name).eq("Cockadoodledoo");
  expect(event.invitees.length).eq(2);
  expect(event.availability).eq("busy");
  expect(event.visibility).eq("normal");
});
