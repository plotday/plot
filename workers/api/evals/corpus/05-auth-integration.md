---
id: auth-integration
category: integration
difficulty: hard
assertions:
  - match: 'Integrations|integrations'
    why: must use the integrations/auth tooling
  - match: 'createThread|saveLink'
    why: issues must land as threads
allowDeps: []
---
# My GitHub issues

Connect to my GitHub account (I'll authorize access when prompted). Once
connected, bring in the open issues assigned to me as task threads — one
thread per issue, titled with the issue title, with a note containing the
issue body and a link to it on GitHub. Check for newly assigned issues
periodically and add them as they appear.
