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
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: string
          calendars: unknown | null
          organization: unknown | null
        }
        Insert: {
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          domain_id?: number | null
          email?: string | null
          id?: never
          provider: Database["public"]["Enums"]["provider"]
          user_id: string
        }
        Update: {
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          domain_id?: number | null
          email?: string | null
          id?: never
          provider?: Database["public"]["Enums"]["provider"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_domain_id_fkey"
            columns: ["domain_id"]
            isOneToOne: false
            referencedRelation: "domain"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      activity: {
        Row: {
          created_at: string
          id: number
          name: string
          path: unknown
          pomodoro: number
          user_id: string
          budget: unknown | null
        }
        Insert: {
          created_at?: string
          id?: never
          name: string
          path: unknown
          pomodoro?: number
          user_id: string
        }
        Update: {
          created_at?: string
          id?: never
          name?: string
          path?: unknown
          pomodoro?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "activity_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      budget: {
        Row: {
          activity_id: number | null
          budget: number | null
          created_at: string
          id: number
          order: string | null
          user_id: string
          week: unknown | null
        }
        Insert: {
          activity_id?: number | null
          budget?: number | null
          created_at?: string
          id?: never
          order?: string | null
          user_id: string
          week?: unknown | null
        }
        Update: {
          activity_id?: number | null
          budget?: number | null
          created_at?: string
          id?: never
          order?: string | null
          user_id?: string
          week?: unknown | null
        }
        Relationships: [
          {
            foreignKeyName: "budget_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "budget_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["activity_id"]
          },
          {
            foreignKeyName: "budget_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      calendar: {
        Row: {
          account_id: number
          created_at: string
          enabled: boolean
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          synced_dates: unknown | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
          account: unknown | null
        }
        Insert: {
          account_id: number
          created_at?: string
          enabled?: boolean
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: never
          name?: string | null
          provider_id: string
          ready?: boolean
          sequence?: number
          sync_error?: string | null
          sync_state?: string | null
          synced_at?: string | null
          synced_dates?: unknown | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Update: {
          account_id?: number
          created_at?: string
          enabled?: boolean
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: never
          name?: string | null
          provider_id?: string
          ready?: boolean
          sequence?: number
          sync_error?: string | null
          sync_state?: string | null
          synced_at?: string | null
          synced_dates?: unknown | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "calendar_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "account"
            referencedColumns: ["id"]
          }
        ]
      }
      contact: {
        Row: {
          avatar_url: string | null
          created_at: string
          domain_id: number | null
          email: string
          id: number
          is_self: boolean
          name: string | null
          user_id: string
          organization: unknown | null
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          domain_id?: number | null
          email: string
          id?: never
          is_self?: boolean
          name?: string | null
          user_id: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          domain_id?: number | null
          email?: string
          id?: never
          is_self?: boolean
          name?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_domain_id_fkey"
            columns: ["domain_id"]
            isOneToOne: false
            referencedRelation: "domain"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      domain: {
        Row: {
          created_at: string
          domain: string
          id: number
          organization_id: number | null
        }
        Insert: {
          created_at?: string
          domain: string
          id?: never
          organization_id?: number | null
        }
        Update: {
          created_at?: string
          domain?: string
          id?: never
          organization_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organization"
            referencedColumns: ["id"]
          }
        ]
      }
      event: {
        Row: {
          at: unknown
          availability: Database["public"]["Enums"]["event_availability"]
          calendar_id: number | null
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
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id?: number | null
          conferencing_url?: string | null
          created_at?: string
          description?: string | null
          id?: never
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
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id?: number | null
          conferencing_url?: string | null
          created_at?: string
          description?: string | null
          id?: never
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
            isOneToOne: false
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          }
        ]
      }
      invitation: {
        Row: {
          code: string
          created_at: string
          id: number
          remaining: number
        }
        Insert: {
          code: string
          created_at?: string
          id?: never
          remaining?: number
        }
        Update: {
          code?: string
          created_at?: string
          id?: never
          remaining?: number
        }
        Relationships: []
      }
      invitee: {
        Row: {
          created_at: string
          email: string
          event_id: number | null
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
          contact: unknown | null
        }
        Insert: {
          created_at?: string
          email: string
          event_id?: number | null
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
        }
        Update: {
          created_at?: string
          email?: string
          event_id?: number | null
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
        }
        Relationships: [
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event"
            referencedColumns: ["id"]
          }
        ]
      }
      note: {
        Row: {
          activity_id: number | null
          body: string
          created_at: string
          id: number
          user_id: string
        }
        Insert: {
          activity_id?: number | null
          body: string
          created_at?: string
          id?: never
          user_id: string
        }
        Update: {
          activity_id?: number | null
          body?: string
          created_at?: string
          id?: never
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["activity_id"]
          },
          {
            foreignKeyName: "note_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
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
          id?: never
          name: string
        }
        Update: {
          created_at?: string
          id?: never
          name?: string
        }
        Relationships: []
      }
      raw_event: {
        Row: {
          calendar_id: number | null
          created_at: string
          event: Json
          id: number
          provider_id: string
        }
        Insert: {
          calendar_id?: number | null
          created_at?: string
          event: Json
          id?: never
          provider_id: string
        }
        Update: {
          calendar_id?: number | null
          created_at?: string
          event?: Json
          id?: never
          provider_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "raw_event_calendar_id_fkey"
            columns: ["calendar_id"]
            isOneToOne: false
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          }
        ]
      }
      rule: {
        Row: {
          activity_id: number | null
          calendar_id: number | null
          created_at: string
          id: number
          internal: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain: string | null
          invitees: string[] | null
          name: string | null
          series: string | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: string
        }
        Insert: {
          activity_id?: number | null
          calendar_id?: number | null
          created_at?: string
          id?: never
          internal?: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain?: string | null
          invitees?: string[] | null
          name?: string | null
          series?: string | null
          type?: Database["public"]["Enums"]["event_type"] | null
          user_id: string
        }
        Update: {
          activity_id?: number | null
          calendar_id?: number | null
          created_at?: string
          id?: never
          internal?: Database["public"]["Enums"]["event_internal"] | null
          invitee_domain?: string | null
          invitees?: string[] | null
          name?: string | null
          series?: string | null
          type?: Database["public"]["Enums"]["event_type"] | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rule_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rule_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["activity_id"]
          },
          {
            foreignKeyName: "rule_calendar_id_fkey"
            columns: ["calendar_id"]
            isOneToOne: false
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rule_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      time: {
        Row: {
          activity_id: number | null
          at: unknown
          created_at: string
          event_id: number | null
          id: number
          planned: number
          remaining: number
          series_id: number | null
          status: Database["public"]["Enums"]["time_status"]
          user_id: string
        }
        Insert: {
          activity_id?: number | null
          at: unknown
          created_at?: string
          event_id?: number | null
          id?: never
          planned: number
          remaining?: number
          series_id?: number | null
          status?: Database["public"]["Enums"]["time_status"]
          user_id: string
        }
        Update: {
          activity_id?: number | null
          at?: unknown
          created_at?: string
          event_id?: number | null
          id?: never
          planned?: number
          remaining?: number
          series_id?: number | null
          status?: Database["public"]["Enums"]["time_status"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "time_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["activity_id"]
          },
          {
            foreignKeyName: "time_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_series_id_fkey"
            columns: ["series_id"]
            isOneToOne: false
            referencedRelation: "time"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      waitlist: {
        Row: {
          activated_at: string | null
          created_at: string
          email: string
          id: number
          invitation: string | null
        }
        Insert: {
          activated_at?: string | null
          created_at?: string
          email: string
          id?: number
          invitation?: string | null
        }
        Update: {
          activated_at?: string | null
          created_at?: string
          email?: string
          id?: number
          invitation?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      event_x: {
        Row: {
          activity_id: number | null
          activity_path: unknown | null
          all_day: boolean | null
          at: unknown | null
          attendee_count: number | null
          availability: Database["public"]["Enums"]["event_availability"] | null
          calendar_id: number | null
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
          user_id: string | null
          visibility: Database["public"]["Enums"]["event_visibility"] | null
        }
        Relationships: [
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
      }
      gap: {
        Row: {
          at: unknown | null
          day: string | null
          minutes: number | null
          user_id: string | null
        }
        Relationships: []
      }
      gap_daily: {
        Row: {
          day: string | null
          focus: number | null
          total: number | null
          user_id: string | null
        }
        Relationships: []
      }
      gap_monthly: {
        Row: {
          focus: number | null
          month: string | null
          total: number | null
          user_id: string | null
        }
        Relationships: []
      }
      insight: {
        Row: {
          activity_path: unknown | null
          count: number | null
          day: string | null
          minutes: number | null
          name: string | null
          response: Database["public"]["Enums"]["event_response"] | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: string | null
          value: string | null
        }
        Relationships: [
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          }
        ]
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
          user_id: string | null
          value: string | null
          week: unknown | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
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
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: string
        }[]
      }
      all_views_secure: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
      budget: {
        Args: {
          "": unknown
        }
        Returns: {
          activity_id: number | null
          budget: number | null
          created_at: string
          id: number
          order: string | null
          user_id: string
          week: unknown | null
        }[]
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
          created_at: string
          enabled: boolean
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          synced_dates: unknown | null
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
          created_at: string
          enabled: boolean
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          name: string | null
          provider_id: string
          ready: boolean
          sequence: number
          sync_error: string | null
          sync_state: string | null
          synced_at: string | null
          synced_dates: unknown | null
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
          created_at: string
          domain_id: number | null
          email: string
          id: number
          is_self: boolean
          name: string | null
          user_id: string
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
          event_id: number | null
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
        }[]
      }
      is_finite: {
        Args: {
          test: unknown
        }
        Returns: boolean
      }
      is_lower: {
        Args: {
          "": string
        }
        Returns: boolean
      }
      is_week: {
        Args: {
          p_week: unknown
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
      user_timezone: {
        Args: Record<PropertyKey, never>
        Returns: string
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
      time_status: "started" | "skipped" | "stopped"
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
          owner_id: string | null
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
          owner_id?: string | null
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
          owner_id?: string | null
          public?: boolean | null
          updated_at?: string | null
        }
        Relationships: []
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
          owner_id: string | null
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
          owner_id?: string | null
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
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
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

export type Tables<
  PublicTableNameOrOptions extends
    | keyof (Database["public"]["Tables"] & Database["public"]["Views"])
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
        Database[PublicTableNameOrOptions["schema"]]["Views"])
    : never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
      Database[PublicTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : PublicTableNameOrOptions extends keyof (Database["public"]["Tables"] &
      Database["public"]["Views"])
  ? (Database["public"]["Tables"] &
      Database["public"]["Views"])[PublicTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  PublicTableNameOrOptions extends
    | keyof Database["public"]["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : PublicTableNameOrOptions extends keyof Database["public"]["Tables"]
  ? Database["public"]["Tables"][PublicTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  PublicTableNameOrOptions extends
    | keyof Database["public"]["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : PublicTableNameOrOptions extends keyof Database["public"]["Tables"]
  ? Database["public"]["Tables"][PublicTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  PublicEnumNameOrOptions extends
    | keyof Database["public"]["Enums"]
    | { schema: keyof Database },
  EnumName extends PublicEnumNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = PublicEnumNameOrOptions extends { schema: keyof Database }
  ? Database[PublicEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : PublicEnumNameOrOptions extends keyof Database["public"]["Enums"]
  ? Database["public"]["Enums"][PublicEnumNameOrOptions]
  : never

