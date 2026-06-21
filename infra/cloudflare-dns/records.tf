# plot.day DNS records, imported faithfully from Cloudflare (zone 557983dc...).
# Generated via `terraform plan -generate-config-out`, then imported and verified
# zero-diff. `pnpm tf cloudflare-dns plan` must report no changes.

# Please review these resources and move them into your main configuration files.

resource "cloudflare_dns_record" "mx_root_5" {
  comment         = null
  content         = "aspmx.l.google.com"
  data            = null
  name            = "plot.day"
  priority        = 1
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_preview" {
  comment         = null
  content         = "staging.calendar-we8.pages.dev"
  data            = null
  name            = "preview.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_clk2_domainkey" {
  comment         = null
  content         = "dkim2.hsf2pgrq4yx9.clerk.services"
  data            = null
  name            = "clk2._domainkey.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_app" {
  comment         = null
  content         = "calendar-we8.pages.dev"
  data            = null
  name            = "app.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_domainconnect" {
  comment         = null
  content         = "connect.domains.google.com"
  data            = null
  name            = "_domainconnect.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_build" {
  comment         = null
  content         = "twist"
  data            = null
  name            = "build.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_send_updates" {
  comment         = null
  content         = "\"v=spf1 include:amazonses.com -all\""
  data            = null
  name            = "send.updates.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "mx_root" {
  comment         = null
  content         = "alt4.aspmx.l.google.com"
  data            = null
  name            = "plot.day"
  priority        = 10
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "aaaa_api" {
  comment         = null
  content         = "100::"
  data            = null
  name            = "api.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "AAAA"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_google_domainkey" {
  comment         = null
  content         = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkhpzAPqR725wGu6VzrYQk1QBDdiz4A2Pl8i2n1zNEecnUuV0WNgBY0mkVeCAYNyYnkRS/4gKQ+Gm4JdZpxbWpbX2mBVT7SaE8t9lqeqvl8GjhX1oGbLyuM30Hw7neAcBG8156SUv3PNF8+nJamtHbd5LfFYEzW7Uelmny5258cdA9b4kYnRAeGwdRRXfDhHZvSn+E7QkbjfX0LUeVcRCRDMXhr8+wFm67C9RvEism3dysexfV3MFFMjT+STMn60AffSs778RJ5FYx7zaGXqMIRohzpfSry+vf9n/0CtzbnYbJIPKAnRTpZD6efm9LTsu49jqmdBAhPkjWVC+E1wBJwIDAQAB"
  data            = null
  name            = "google._domainkey.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_api" {
  comment         = null
  content         = "ca3-728ef6378ffa47e0a26434ddff059ee9"
  data            = null
  name            = "api.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_dmarc_updates" {
  comment         = "Recommended by CC"
  content         = "\"v=DMARC1; p=none; rua=mailto:21bf4e1e50f742feb9d633437f6c3b9d@dmarc-reports.cloudflare.net\""
  data            = null
  name            = "_dmarc.updates.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_api_kris" {
  comment         = null
  content         = "562c17e2-ac51-458c-8066-af5ba9547e77.cfargotunnel.com"
  data            = null
  name            = "api-kris.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "mx_root_2" {
  comment         = null
  content         = "alt2.aspmx.l.google.com"
  data            = null
  name            = "plot.day"
  priority        = 5
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_acme_challenge_sync" {
  comment         = "Supabase custom domain verification"
  content         = "\"ha-gqtf2r4GbfCUMHXJ0_Rtlg3azKCG6lVoAu9NWCOY\""
  data            = null
  name            = "_acme-challenge.sync.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "mx_send_updates" {
  comment         = null
  content         = "feedback-smtp.us-east-1.amazonses.com"
  data            = null
  name            = "send.updates.plot.day"
  priority        = 10
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_dev" {
  comment         = null
  content         = "d6d38e4f-330c-4a12-8791-f39658309da4.cfargotunnel.com"
  data            = null
  name            = "dev.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_root_2" {
  comment         = null
  content         = "v=spf1 include:_spf.google.com -all"
  data            = null
  name            = "plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_resend_domainkey_updates" {
  comment         = null
  content         = "\"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCjxsLDnZBZ1bFiQdCfy4aYW6zFDUds+WtnGDjA6wRPxBRa4zdBVp3F7AmbsxzvJowTpeDne2sZlaLwUwfEU6UiTovvBkVeY77F5S8ZGIcVnIHEMri1bE+NRaEoeFodtUdRBd+3XiiFI8s4zDretQoN3RTzoNJM0gRw4xBCTsPNQwIDAQAB\""
  data            = null
  name            = "resend._domainkey.updates.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_root_3" {
  comment         = null
  content         = "\"google-site-verification=GrgzZuODXWYBHm0hV0ZiVP2hBzLcBOZgYg9qbxCm4TY\""
  data            = null
  name            = "plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "aaaa_beat" {
  comment         = null
  content         = "100::"
  data            = null
  name            = "beat.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "AAAA"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_clk_domainkey" {
  comment         = null
  content         = "dkim1.hsf2pgrq4yx9.clerk.services"
  data            = null
  name            = "clk._domainkey.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_twist" {
  comment         = null
  content         = "plotday.github.io"
  data            = null
  name            = "twist.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_sync" {
  comment         = null
  content         = "bgupcdfsucwufyxvqbej.supabase.co"
  data            = null
  name            = "sync.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_clerk" {
  comment         = null
  content         = "frontend-api.clerk.services"
  data            = null
  name            = "clerk.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "mx_root_4" {
  comment         = null
  content         = "alt3.aspmx.l.google.com"
  data            = null
  name            = "plot.day"
  priority        = 10
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_cf_custom_hostname_api" {
  comment         = null
  content         = "d7fdc275-2b70-4c11-9a62-1b6e628abf78"
  data            = null
  name            = "_cf-custom-hostname.api.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_dmarc" {
  comment         = null
  content         = "v=DMARC1;  p=none; rua=mailto:21bf4e1e50f742feb9d633437f6c3b9d@dmarc-reports.cloudflare.net"
  data            = null
  name            = "_dmarc.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "aaaa_root" {
  comment         = null
  content         = "100::"
  data            = null
  name            = "plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "AAAA"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "mx_root_3" {
  comment         = null
  content         = "alt1.aspmx.l.google.com"
  data            = null
  name            = "plot.day"
  priority        = 5
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 3600
  type    = "MX"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_download" {
  comment         = null
  content         = "public.r2.dev"
  data            = null
  name            = "download.plot.day"
  priority        = null
  private_routing = null
  proxied         = true
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "txt_root" {
  comment         = "Microsoft Entra domain verification"
  content         = "\"MS=ms71439299\""
  data            = null
  name            = "plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = null
    ipv4_only     = null
    ipv6_only     = null
  }
  tags    = []
  ttl     = 1
  type    = "TXT"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_clkmail" {
  comment         = null
  content         = "mail.hsf2pgrq4yx9.clerk.services"
  data            = null
  name            = "clkmail.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}

resource "cloudflare_dns_record" "cname_accounts" {
  comment         = null
  content         = "accounts.clerk.services"
  data            = null
  name            = "accounts.plot.day"
  priority        = null
  private_routing = null
  proxied         = false
  settings = {
    flatten_cname = false
    ipv4_only     = false
    ipv6_only     = false
  }
  tags    = []
  ttl     = 1
  type    = "CNAME"
  zone_id = "557983dcc52dc44b74894b16c6a8979b"
}
