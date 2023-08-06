# Google

## OAuth Setup

1. [Create an organization](https://console.cloud.google.com/cloud-setup/organization)
1. [Create a project](https://console.cloud.google.com/projectcreate)
1. [Enabled the Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com)
1. Add the support email to IAM
   1. Click [Grant access](https://console.cloud.google.com/iam-admin/iam)
   1. Enter the email address as `New principals`
1. [Create credentials](https://console.cloud.google.com/apis/credentials) - `OAuth client ID`
   1. For development, add `Authorized redirect URIs`: `http://localhost:54321/auth/v1/callback`
   1. For production, add `Authorized redirect URIs`: `https://api.plot.day/auth/v1/callback`
