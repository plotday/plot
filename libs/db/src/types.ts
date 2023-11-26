export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export interface Database {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          operationName?: string
          query?: string
          variables?: Json
          extensions?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      account: {
        Row: {
          auth_user_id: string
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
          calendars: unknown | null
          organization: unknown | null
        }
        Insert: {
          auth_user_id: string
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          domain_id?: number | null
          email?: string | null
          id?: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
        }
        Update: {
          auth_user_id?: string
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          domain_id?: number | null
          email?: string | null
          id?: number
          provider?: Database["public"]["Enums"]["provider"]
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "account_auth_user_id_fkey"
            columns: ["auth_user_id"]
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_domain_id_fkey"
            columns: ["domain_id"]
            referencedRelation: "domain"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          }
        ]
      }
      calendar: {
        Row: {
          account_id: number
          category: string | null
          created_at: string
          enabled: boolean
          ends_at: string | null
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          starts_at: string | null
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
          account: unknown | null
        }
        Insert: {
          account_id: number
          category?: string | null
          created_at?: string
          enabled?: boolean
          ends_at?: string | null
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: number
          name?: string | null
          provider_id: string
          ready?: boolean
          sequence?: number
          starts_at?: string | null
          sync_error?: string | null
          sync_state?: string | null
          synced_at?: string | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Update: {
          account_id?: number
          category?: string | null
          created_at?: string
          enabled?: boolean
          ends_at?: string | null
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: number
          name?: string | null
          provider_id?: string
          ready?: boolean
          sequence?: number
          starts_at?: string | null
          sync_error?: string | null
          sync_state?: string | null
          synced_at?: string | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "calendar_account_id_fkey"
            columns: ["account_id"]
            referencedRelation: "account"
            referencedColumns: ["id"]
          }
        ]
      }
      category: {
        Row: {
          budget_weekly: number | null
          created_at: string | null
          id: number
          minimize: boolean
          name: string
          path: unknown
          priority: string
          user_id: number
        }
        Insert: {
          budget_weekly?: number | null
          created_at?: string | null
          id?: number
          minimize?: boolean
          name: string
          path: unknown
          priority?: string
          user_id: number
        }
        Update: {
          budget_weekly?: number | null
          created_at?: string | null
          id?: number
          minimize?: boolean
          name?: string
          path?: unknown
          priority?: string
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          }
        ]
      }
      contact: {
        Row: {
          avatar_url: string | null
          contact_user_id: number | null
          created_at: string
          domain_id: number | null
          email: string | null
          id: number
          name: string | null
          user_id: number
          organization: unknown | null
        }
        Insert: {
          avatar_url?: string | null
          contact_user_id?: number | null
          created_at?: string
          domain_id?: number | null
          email?: string | null
          id?: number
          name?: string | null
          user_id: number
        }
        Update: {
          avatar_url?: string | null
          contact_user_id?: number | null
          created_at?: string
          domain_id?: number | null
          email?: string | null
          id?: number
          name?: string | null
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "contact_contact_user_id_fkey"
            columns: ["contact_user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_contact_user_id_fkey"
            columns: ["contact_user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "contact_contact_user_id_fkey"
            columns: ["contact_user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "contact_domain_id_fkey"
            columns: ["domain_id"]
            referencedRelation: "domain"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          }
        ]
      }
      domain: {
        Row: {
          created_at: string | null
          domain: string
          id: number
          organization_id: number | null
        }
        Insert: {
          created_at?: string | null
          domain: string
          id?: number
          organization_id?: number | null
        }
        Update: {
          created_at?: string | null
          domain?: string
          id?: number
          organization_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          }
        ]
      }
      event: {
        Row: {
          at: unknown
          attended: unknown | null
          availability: Database["public"]["Enums"]["event_availability"]
          calendar_id: number
          conferencing_url: string | null
          created_at: string
          description: string | null
          id: number
          invitees_hidden: boolean
          name: string | null
          organizer_email: string | null
          provider_id: string
          provider_link: string | null
          sequence: number
          series: string | null
          status: Database["public"]["Enums"]["event_status"]
          summary: string | null
          visibility: Database["public"]["Enums"]["event_visibility"]
        }
        Insert: {
          at: unknown
          attended?: unknown | null
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id: number
          conferencing_url?: string | null
          created_at?: string
          description?: string | null
          id?: number
          invitees_hidden?: boolean
          name?: string | null
          organizer_email?: string | null
          provider_id: string
          provider_link?: string | null
          sequence?: number
          series?: string | null
          status?: Database["public"]["Enums"]["event_status"]
          summary?: string | null
          visibility?: Database["public"]["Enums"]["event_visibility"]
        }
        Update: {
          at?: unknown
          attended?: unknown | null
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id?: number
          conferencing_url?: string | null
          created_at?: string
          description?: string | null
          id?: number
          invitees_hidden?: boolean
          name?: string | null
          organizer_email?: string | null
          provider_id?: string
          provider_link?: string | null
          sequence?: number
          series?: string | null
          status?: Database["public"]["Enums"]["event_status"]
          summary?: string | null
          visibility?: Database["public"]["Enums"]["event_visibility"]
        }
        Relationships: [
          {
            foreignKeyName: "event_calendar_id_fkey"
            columns: ["calendar_id"]
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          }
        ]
      }
      event_rule: {
        Row: {
          calendar_id: number | null
          category_id: number | null
          created_at: string | null
          id: number
          internal: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain: string | null
          invitees: string[] | null
          name: string | null
          series: string | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: number
        }
        Insert: {
          calendar_id?: number | null
          category_id?: number | null
          created_at?: string | null
          id?: number
          internal?: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain?: string | null
          invitees?: string[] | null
          name?: string | null
          series?: string | null
          type?: Database["public"]["Enums"]["event_type"] | null
          user_id: number
        }
        Update: {
          calendar_id?: number | null
          category_id?: number | null
          created_at?: string | null
          id?: number
          internal?: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain?: string | null
          invitees?: string[] | null
          name?: string | null
          series?: string | null
          type?: Database["public"]["Enums"]["event_type"] | null
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "event_rule_calendar_id_fkey"
            columns: ["calendar_id"]
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_rule_category_id_fkey"
            columns: ["category_id"]
            referencedRelation: "category"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_rule_category_id_fkey"
            columns: ["category_id"]
            referencedRelation: "event_x"
            referencedColumns: ["category_id"]
          },
          {
            foreignKeyName: "event_rule_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_rule_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "event_rule_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          }
        ]
      }
      invitation: {
        Row: {
          code: string
          created_at: string | null
          id: number
          remaining: number
        }
        Insert: {
          code: string
          created_at?: string | null
          id?: number
          remaining?: number
        }
        Update: {
          code?: string
          created_at?: string | null
          id?: number
          remaining?: number
        }
        Relationships: []
      }
      invitee: {
        Row: {
          created_at: string
          email: string
          event_id: number
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
          contact: unknown | null
        }
        Insert: {
          created_at?: string
          email: string
          event_id: number
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
        }
        Update: {
          created_at?: string
          email?: string
          event_id?: number
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
        }
        Relationships: [
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            referencedRelation: "event"
            referencedColumns: ["id"]
          }
        ]
      }
      organization: {
        Row: {
          created_at: string
          id: number
          name: string
        }
        Insert: {
          created_at?: string
          id?: number
          name: string
        }
        Update: {
          created_at?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      raw_event: {
        Row: {
          calendar_id: number
          created_at: string
          event: Json
          id: number
          provider_id: string
        }
        Insert: {
          calendar_id: number
          created_at?: string
          event: Json
          id?: number
          provider_id: string
        }
        Update: {
          calendar_id?: number
          created_at?: string
          event?: Json
          id?: number
          provider_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "raw_event_calendar_id_fkey"
            columns: ["calendar_id"]
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          }
        ]
      }
      user: {
        Row: {
          activated_at: string | null
          avatar_url: string | null
          created_at: string
          default_category: string | null
          email: string
          id: number
          invitation: string | null
          name: string | null
          timezone: string | null
        }
        Insert: {
          activated_at?: string | null
          avatar_url?: string | null
          created_at?: string
          default_category?: string | null
          email: string
          id?: number
          invitation?: string | null
          name?: string | null
          timezone?: string | null
        }
        Update: {
          activated_at?: string | null
          avatar_url?: string | null
          created_at?: string
          default_category?: string | null
          email?: string
          id?: number
          invitation?: string | null
          name?: string | null
          timezone?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      event_x: {
        Row: {
          all_day: boolean | null
          at: unknown | null
          attendee_count: number | null
          availability: Database["public"]["Enums"]["event_availability"] | null
          calendar_id: number | null
          category_id: number | null
          category_path: unknown | null
          conferencing_url: string | null
          created_at: string | null
          day: string | null
          description: string | null
          id: number | null
          initiated: boolean | null
          internal: Database["public"]["Enums"]["event_internal"] | null
          invitee_count: number | null
          invitee_domains: string[] | null
          invitees: string[] | null
          invitees_hidden: boolean | null
          minutes: number | null
          name: string | null
          notice: number | null
          organizer_email: string | null
          provider_id: string | null
          provider_link: string | null
          recurring: boolean | null
          response: Database["public"]["Enums"]["event_response"] | null
          rounded_length: number | null
          series: string | null
          size: string | null
          speedy: boolean | null
          status: Database["public"]["Enums"]["event_status"] | null
          summary: string | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: number | null
          visibility: Database["public"]["Enums"]["event_visibility"] | null
        }
        Relationships: []
      }
      gap: {
        Row: {
          at: unknown | null
          day: string | null
          minutes: number | null
          user_id: number | null
        }
        Relationships: []
      }
      gap_daily: {
        Row: {
          day: string | null
          focus: number | null
          total: number | null
          user_id: number | null
        }
        Relationships: []
      }
      gap_monthly: {
        Row: {
          focus: number | null
          month: string | null
          total: number | null
          user_id: number | null
        }
        Relationships: []
      }
      insight: {
        Row: {
          category_path: unknown | null
          count: number | null
          day: string | null
          minutes: number | null
          name: string | null
          response: Database["public"]["Enums"]["event_response"] | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: number | null
          value: string | null
        }
        Relationships: []
      }
      insight_weekly: {
        Row: {
          count: number | null
          minutes: number | null
          name: string | null
          path: unknown | null
          pending_count: number | null
          pending_minutes: number | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: number | null
          value: string | null
          week: unknown | null
        }
        Relationships: [
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "category_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "insight"
            referencedColumns: ["user_id"]
          }
        ]
      }
      invitation_admin: {
        Row: {
          code: string | null
          created_at: string | null
          id: number | null
          remaining: number | null
          uses: number | null
        }
        Relationships: []
      }
      sync_admin: {
        Row: {
          account_id: number | null
          calendar_provider_id: string | null
          email: string | null
          error: string | null
          event_count: number | null
          first_synced_at: string | null
          full_sync_at: string | null
          provider: Database["public"]["Enums"]["provider"] | null
          sync_seconds: number | null
          synced_at: string | null
        }
        Relationships: []
      }
      waitlist_admin: {
        Row: {
          created_at: string | null
          email: string | null
          event_count: number | null
          id: number | null
          invitation: string | null
          provider: Database["public"]["Enums"]["provider"][] | null
          status: string | null
          sync_accounts: string[] | null
          sync_error: string[] | null
        }
        Relationships: []
      }
    }
    Functions: {
      account: {
        Args: {
          "": unknown
        }
        Returns: {
          auth_user_id: string
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
        }[]
      }
      accounts: {
        Args: {
          "": unknown
        }
        Returns: {
          auth_user_id: string
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
        }[]
      }
      all_views_secure: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
      calc_all_day: {
        Args: {
          at: unknown
        }
        Returns: boolean
      }
      calc_event_type: {
        Args: {
          at: unknown
          availability: Database["public"]["Enums"]["event_availability"]
          response: Database["public"]["Enums"]["event_response"]
          has_invitees: boolean
        }
        Returns: Database["public"]["Enums"]["event_type"]
      }
      calc_internal: {
        Args: {
          invitee_count: number
          user_domain: number
          domains: number[]
        }
        Returns: Database["public"]["Enums"]["event_internal"]
      }
      calc_meeting_size: {
        Args: {
          invitee_count: number
        }
        Returns: string
      }
      calc_minutes: {
        Args: {
          at: unknown
        }
        Returns: number
      }
      calc_notice: {
        Args: {
          created_at: string
          at: unknown
        }
        Returns: number
      }
      calc_rounded_length: {
        Args: {
          at: unknown
        }
        Returns: number
      }
      calc_speedy: {
        Args: {
          at: unknown
        }
        Returns: boolean
      }
      calendar: {
        Args: {
          "": unknown
        }
        Returns: {
          account_id: number
          category: string | null
          created_at: string
          enabled: boolean
          ends_at: string | null
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          starts_at: string | null
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
        }[]
      }
      calendars: {
        Args: {
          "": unknown
        }
        Returns: {
          account_id: number
          category: string | null
          created_at: string
          enabled: boolean
          ends_at: string | null
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          starts_at: string | null
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
        }[]
      }
      cancel_events: {
        Args: {
          _events: Database["public"]["CompositeTypes"]["event_ids"][]
        }
        Returns: undefined
      }
      contact: {
        Args: {
          "": unknown
        }
        Returns: {
          avatar_url: string | null
          contact_user_id: number | null
          created_at: string
          domain_id: number | null
          email: string | null
          id: number
          name: string | null
          user_id: number
        }[]
      }
      domain: {
        Args: {
          "": unknown
        }
        Returns: {
          created_at: string | null
          domain: string
          id: number
          organization_id: number | null
        }[]
      }
      extract_minutes: {
        Args: {
          r: unknown
        }
        Returns: number
      }
      get_or_create_domain_id: {
        Args: {
          email: string
        }
        Returns: number
      }
      invitee: {
        Args: {
          "": unknown
        }
        Returns: {
          created_at: string
          email: string
          event_id: number
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
        }[]
      }
      is_user_account: {
        Args: {
          auth_user_id: string
          user_id: number
        }
        Returns: boolean
      }
      organization:
        | {
            Args: {
              "": unknown
            }
            Returns: {
              created_at: string
              id: number
              name: string
            }[]
          }
        | {
            Args: {
              "": unknown
            }
            Returns: {
              created_at: string
              id: number
              name: string
            }[]
          }
      redeem_invitation: {
        Args: {
          _user_id: number
          _invitation: string
        }
        Returns: undefined
      }
      upsert_contacts: {
        Args: {
          _contacts: Database["public"]["CompositeTypes"]["contact_upsert"][]
        }
        Returns: undefined
      }
      upsert_invitees: {
        Args: {
          _event_ids: number[]
          _invitees: Database["public"]["CompositeTypes"]["invitee_upsert"][]
        }
        Returns: undefined
      }
      week_from_date: {
        Args: {
          d: string
        }
        Returns: unknown
      }
      work_day_end: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      work_day_start: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
    }
    Enums: {
      event_availability: "busy" | "away" | "focus" | "free"
      event_internal: "internal" | "external"
      event_response: "accepted" | "declined" | "tentative"
      event_status: "confirmed" | "cancelled" | "tentative"
      event_type: "meeting" | "task" | "note"
      event_visibility:
        | "normal"
        | "private"
        | "confidential"
        | "public"
        | "personal"
      location_type: "room" | "address" | "other"
      meeting_size: "1:1" | "Small" | "Medium" | "Large" | "XL" | "XXL"
      provider: "google" | "outlook"
      user_status: "waitlisted" | "active"
    }
    CompositeTypes: {
      contact_upsert: {
        calendar_id: number
        email: string
        name: string
        avatar_url: string
      }
      event_ids: {
        calendar_id: number
        provider_id: string
      }
      invitee_upsert: {
        event_id: number
        email: string
        response: Database["public"]["Enums"]["event_response"]
        is_optional: boolean
      }
    }
  }
  storage: {
    Tables: {
      buckets: {
        Row: {
          allowed_mime_types: string[] | null
          avif_autodetection: boolean | null
          created_at: string | null
          file_size_limit: number | null
          id: string
          name: string
          owner: string | null
          public: boolean | null
          updated_at: string | null
        }
        Insert: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id: string
          name: string
          owner?: string | null
          public?: boolean | null
          updated_at?: string | null
        }
        Update: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id?: string
          name?: string
          owner?: string | null
          public?: boolean | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "buckets_owner_fkey"
            columns: ["owner"]
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      migrations: {
        Row: {
          executed_at: string | null
          hash: string
          id: number
          name: string
        }
        Insert: {
          executed_at?: string | null
          hash: string
          id: number
          name: string
        }
        Update: {
          executed_at?: string | null
          hash?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      objects: {
        Row: {
          bucket_id: string | null
          created_at: string | null
          id: string
          last_accessed_at: string | null
          metadata: Json | null
          name: string | null
          owner: string | null
          path_tokens: string[] | null
          updated_at: string | null
          version: string | null
        }
        Insert: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          version?: string | null
        }
        Update: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          }
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      can_insert_object: {
        Args: {
          bucketid: string
          name: string
          owner: string
          metadata: Json
        }
        Returns: undefined
      }
      extension: {
        Args: {
          name: string
        }
        Returns: string
      }
      filename: {
        Args: {
          name: string
        }
        Returns: string
      }
      foldername: {
        Args: {
          name: string
        }
        Returns: unknown
      }
      get_size_by_bucket: {
        Args: Record<PropertyKey, never>
        Returns: {
          size: number
          bucket_id: string
        }[]
      }
      search: {
        Args: {
          prefix: string
          bucketname: string
          limits?: number
          levels?: number
          offsets?: number
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          name: string
          id: string
          updated_at: string
          created_at: string
          last_accessed_at: string
          metadata: Json
        }[]
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

