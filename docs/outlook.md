# Outlook

## OAuth Setup

1. Sign into [Azure Active Directory](https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview)
   1. Make sure you're using an account for the development instance, rather
      than a test account for the testing instance (named "MSFT").
1. [Register a new application](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade/quickStartType~/null/isMSAApp~/true)
   1. For development, add `Authorized redirect URIs`: `http://localhost:54321/auth/v1/callback`
   1. For production, add `Authorized redirect URIs`: `https://api.plot.day/auth/v1/callback`
