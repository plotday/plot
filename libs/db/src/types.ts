export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
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
          deleted_at: string | null
          email: string
          id: number
          updated_at: string
          user_id: string
          calendars: Database["public"]["Tables"]["calendar"]["Row"] | null
          organization:
            | Database["public"]["Tables"]["organization"]["Row"]
            | null
        }
        Insert: {
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          deleted_at?: string | null
          email: string
          id?: never
          updated_at?: string
          user_id: string
        }
        Update: {
          contact_sync_state?: Json | null
          created_at?: string
          credentials?: Json | null
          deleted_at?: string | null
          email?: string
          id?: never
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      calendar: {
        Row: {
          account_id: number
          created_at: string
          deleted_at: string | null
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
          updated_at: string
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
          account: Database["public"]["Tables"]["account"]["Row"] | null
        }
        Insert: {
          account_id: number
          created_at?: string
          deleted_at?: string | null
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
          updated_at?: string
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Update: {
          account_id?: number
          created_at?: string
          deleted_at?: string | null
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
          updated_at?: string
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
          },
        ]
      }
      contact: {
        Row: {
          avatar_url: string | null
          created_at: string
          deleted_at: string | null
          email: string
          id: number
          name: string | null
          updated_at: string
          user_id: string
          organization:
            | Database["public"]["Tables"]["organization"]["Row"]
            | null
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          email: string
          id?: never
          name?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string
          id?: never
          name?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      domain: {
        Row: {
          created_at: string
          id: number
          name: string
          organization_id: number | null
        }
        Insert: {
          created_at?: string
          id?: never
          name: string
          organization_id?: number | null
        }
        Update: {
          created_at?: string
          id?: never
          name?: string
          organization_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
        ]
      }
      event: {
        Row: {
          at: unknown
          availability: Database["public"]["Enums"]["event_availability"]
          calendar_id: number | null
          conferencing_url: string | null
          created_at: string
          deleted_at: string | null
          description: string | null
          draft: boolean
          id: string
          invitees_hidden: boolean
          name: string | null
          optional: boolean
          organizer_email: string | null
          provider_id: string
          provider_link: string | null
          response: Database["public"]["Enums"]["event_response"] | null
          sequence: number
          series: string | null
          status: Database["public"]["Enums"]["event_status"]
          summary: string | null
          updated_at: string
          user_id: string
          visibility: Database["public"]["Enums"]["event_visibility"]
        }
        Insert: {
          at: unknown
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id?: number | null
          conferencing_url?: string | null
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          draft?: boolean
          id?: string
          invitees_hidden?: boolean
          name?: string | null
          optional?: boolean
          organizer_email?: string | null
          provider_id?: string
          provider_link?: string | null
          response?: Database["public"]["Enums"]["event_response"] | null
          sequence?: number
          series?: string | null
          status?: Database["public"]["Enums"]["event_status"]
          summary?: string | null
          updated_at?: string
          user_id: string
          visibility?: Database["public"]["Enums"]["event_visibility"]
        }
        Update: {
          at?: unknown
          availability?: Database["public"]["Enums"]["event_availability"]
          calendar_id?: number | null
          conferencing_url?: string | null
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          draft?: boolean
          id?: string
          invitees_hidden?: boolean
          name?: string | null
          optional?: boolean
          organizer_email?: string | null
          provider_id?: string
          provider_link?: string | null
          response?: Database["public"]["Enums"]["event_response"] | null
          sequence?: number
          series?: string | null
          status?: Database["public"]["Enums"]["event_status"]
          summary?: string | null
          updated_at?: string
          user_id?: string
          visibility?: Database["public"]["Enums"]["event_visibility"]
        }
        Relationships: [
          {
            foreignKeyName: "event_calendar_id_fkey"
            columns: ["calendar_id"]
            isOneToOne: false
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          },
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
          deleted_at: string | null
          email: string
          event_id: string | null
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
          updated_at: string
          contact: Database["public"]["Tables"]["contact"]["Row"] | null
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          email: string
          event_id?: string | null
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          email?: string
          event_id?: string | null
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["id"]
          },
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
      priority: {
        Row: {
          created_at: string
          created_by: string
          deleted_at: string | null
          do_at: string | null
          done_at: string | null
          draft: boolean
          id: string
          note: string | null
          order: number
          path: unknown
          pinned: boolean
          private: boolean
          root: boolean
          title: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by: string
          deleted_at?: string | null
          do_at?: string | null
          done_at?: string | null
          draft?: boolean
          id?: string
          note?: string | null
          order?: number
          path: unknown
          pinned?: boolean
          private?: boolean
          root?: boolean
          title?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string
          deleted_at?: string | null
          do_at?: string | null
          done_at?: string | null
          draft?: boolean
          id?: string
          note?: string | null
          order?: number
          path?: unknown
          pinned?: boolean
          private?: boolean
          root?: boolean
          title?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      priority_settings: {
        Row: {
          color: number | null
          pomodoro: number | null
          priority_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          color?: number | null
          pomodoro?: number | null
          priority_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          color?: number | null
          pomodoro?: number | null
          priority_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_user: {
        Row: {
          created_at: string
          deleted_at: string | null
          order: number
          path: unknown | null
          priority_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          order?: number
          path?: unknown | null
          priority_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          order?: number
          path?: unknown | null
          priority_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
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
          },
        ]
      }
      series: {
        Row: {
          created_at: string
          embedding: string | null
          id: number
          invitees: string[] | null
          priority_id: string | null
          series: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          embedding?: string | null
          id?: never
          invitees?: string[] | null
          priority_id?: string | null
          series: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          embedding?: string | null
          id?: never
          invitees?: string[] | null
          priority_id?: string | null
          series?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
      }
      session: {
        Row: {
          at: unknown
          created_at: string
          deleted_at: string | null
          id: string
          pomodoro: number | null
          pomodoro_at: string | null
          precedence: number
          priority_id: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          at: unknown
          created_at?: string
          deleted_at?: string | null
          id?: string
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          at?: unknown
          created_at?: string
          deleted_at?: string | null
          id?: string
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
      }
      tag: {
        Row: {
          created_at: string
          emoji: string
          id: number
          priority_id: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          emoji: string
          id?: never
          priority_id?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          emoji?: string
          id?: never
          priority_id?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      balance: {
        Row: {
          count: number | null
          day: string | null
          priority_id: string | null
          seconds: number | null
          type: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      balance_without_children: {
        Row: {
          count: number | null
          day: string | null
          priority_id: string | null
          seconds: number | null
          type: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      event_invitees: {
        Row: {
          attendee_count: number | null
          created_at: string | null
          deleted_at: string | null
          event_id: string | null
          freemail_invitees: boolean | null
          invitee_count: number | null
          invitee_domains: string[] | null
          invitee_organization_ids: number[] | null
          invitees: string[] | null
          size: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["id"]
          },
        ]
      }
      event_x: {
        Row: {
          account_id: number | null
          all_day: boolean | null
          at: unknown | null
          attendee_count: number | null
          availability: Database["public"]["Enums"]["event_availability"] | null
          calendar_id: number | null
          conferencing_url: string | null
          created_at: string | null
          day: string | null
          deleted_at: string | null
          description: string | null
          draft: boolean | null
          embedding: string | null
          external: boolean | null
          id: string | null
          initiated: boolean | null
          invitee_count: number | null
          invitee_domains: string[] | null
          invitees: string[] | null
          invitees_hidden: boolean | null
          name: string | null
          notice: number | null
          organizer_email: string | null
          priority_id: string | null
          priority_path: unknown | null
          provider_id: string | null
          provider_link: string | null
          recurring: boolean | null
          response: Database["public"]["Enums"]["event_response"] | null
          rounded_length: number | null
          seconds: number | null
          series: string | null
          size: string | null
          speedy: boolean | null
          status: Database["public"]["Enums"]["event_status"] | null
          summary: string | null
          type: Database["public"]["Enums"]["event_type"] | null
          updated_at: string | null
          user_id: string | null
          visibility: Database["public"]["Enums"]["event_visibility"] | null
        }
        Relationships: [
          {
            foreignKeyName: "calendar_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "account"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_calendar_id_fkey"
            columns: ["calendar_id"]
            isOneToOne: false
            referencedRelation: "calendar"
            referencedColumns: ["id"]
          },
        ]
      }
      gap: {
        Row: {
          at: unknown | null
          day: string | null
          seconds: number | null
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
          count: number | null
          day: string | null
          name: string | null
          priority_path: unknown | null
          response: Database["public"]["Enums"]["event_response"] | null
          seconds: number | null
          type: Database["public"]["Enums"]["event_type"] | null
          user_id: string | null
          value: string | null
        }
        Relationships: []
      }
      priority_children: {
        Row: {
          child_id: string | null
          id: string | null
        }
        Relationships: []
      }
      priority_tags: {
        Row: {
          priority_id: string | null
          tags: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "event_x"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tag_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_x"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_x: {
        Row: {
          color: number | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          do_at: string | null
          done_at: string | null
          draft: boolean | null
          id: string | null
          note: string | null
          order: number | null
          order_x: number | null
          path: unknown | null
          pinned: boolean | null
          pomodoro: number | null
          private: boolean | null
          root: boolean | null
          tags: Json | null
          title: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      account: {
        Args: { "": Database["public"]["Tables"]["calendar"]["Row"] }
        Returns: {
          contact_sync_state: Json | null
          created_at: string
          credentials: Json | null
          deleted_at: string | null
          email: string
          id: number
          updated_at: string
          user_id: string
        }[]
      }
      all_views_secure: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
      calc_all_day: {
        Args: { at: unknown }
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
        Args: { invitee_count: number; user_domain: number; domains: number[] }
        Returns: Database["public"]["Enums"]["event_internal"]
      }
      calc_meeting_size: {
        Args: { invitee_count: number }
        Returns: string
      }
      calc_notice: {
        Args: { created_at: string; at: unknown }
        Returns: number
      }
      calc_rounded_length: {
        Args: { at: unknown }
        Returns: number
      }
      calc_seconds: {
        Args: { r: unknown }
        Returns: number
      }
      calc_speedy: {
        Args: { at: unknown }
        Returns: boolean
      }
      calendars: {
        Args: { "": Database["public"]["Tables"]["account"]["Row"] }
        Returns: {
          account_id: number
          created_at: string
          deleted_at: string | null
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
          updated_at: string
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
        }[]
      }
      can_access_priority: {
        Args: { _priority_id: string } | { _priority_path: unknown }
        Returns: boolean
      }
      cancel_events: {
        Args: { _events: Database["public"]["CompositeTypes"]["event_ids"][] }
        Returns: undefined
      }
      contact: {
        Args: { "": Database["public"]["Tables"]["invitee"]["Row"] }
        Returns: {
          avatar_url: string | null
          created_at: string
          deleted_at: string | null
          email: string
          id: number
          name: string | null
          updated_at: string
          user_id: string
        }[]
      }
      generate_path: {
        Args: { parent?: unknown }
        Returns: unknown
      }
      get_domain: {
        Args: { email: string }
        Returns: string
      }
      insert_domain: {
        Args: { email: string }
        Returns: number
      }
      is_finite: {
        Args: { test: unknown }
        Returns: boolean
      }
      is_lower: {
        Args: { "": string }
        Returns: boolean
      }
      is_week: {
        Args: { p_week: unknown }
        Returns: boolean
      }
      order_first: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      organization: {
        Args:
          | { "": Database["public"]["Tables"]["account"]["Row"] }
          | { "": Database["public"]["Tables"]["contact"]["Row"] }
        Returns: {
          created_at: string
          id: number
          name: string
        }[]
      }
      parent_path: {
        Args: { p: unknown }
        Returns: unknown
      }
      redeem_invitation: {
        Args: { _user_id: number; _invitation: string }
        Returns: undefined
      }
      server_timestamp: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      upsert_contacts: {
        Args: {
          _contacts: Database["public"]["CompositeTypes"]["contact_upsert"][]
        }
        Returns: undefined
      }
      upsert_invitees: {
        Args: {
          _event_ids: string[]
          _invitees: Database["public"]["CompositeTypes"]["invitee_upsert"][]
        }
        Returns: undefined
      }
      user_timezone: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      week_from_date: {
        Args: { d: string }
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
      event_availability: "busy" | "away" | "focus" | "free" | "location"
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
    }
    CompositeTypes: {
      contact_upsert: {
        calendar_id: number | null
        email: string | null
        name: string | null
        avatar_url: string | null
      }
      event_ids: {
        calendar_id: number | null
        provider_id: string | null
      }
      invitee_upsert: {
        event_id: string | null
        email: string | null
        response: Database["public"]["Enums"]["event_response"] | null
        is_optional: boolean | null
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
          level: number | null
          metadata: Json | null
          name: string | null
          owner: string | null
          owner_id: string | null
          path_tokens: string[] | null
          updated_at: string | null
          user_metadata: Json | null
          version: string | null
        }
        Insert: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          level?: number | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Update: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          level?: number | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      prefixes: {
        Row: {
          bucket_id: string
          created_at: string | null
          level: number
          name: string
          updated_at: string | null
        }
        Insert: {
          bucket_id: string
          created_at?: string | null
          level?: number
          name: string
          updated_at?: string | null
        }
        Update: {
          bucket_id?: string
          created_at?: string | null
          level?: number
          name?: string
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "prefixes_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          in_progress_size: number
          key: string
          owner_id: string | null
          upload_signature: string
          user_metadata: Json | null
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id: string
          in_progress_size?: number
          key: string
          owner_id?: string | null
          upload_signature: string
          user_metadata?: Json | null
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          in_progress_size?: number
          key?: string
          owner_id?: string | null
          upload_signature?: string
          user_metadata?: Json | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads_parts: {
        Row: {
          bucket_id: string
          created_at: string
          etag: string
          id: string
          key: string
          owner_id: string | null
          part_number: number
          size: number
          upload_id: string
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          etag: string
          id?: string
          key: string
          owner_id?: string | null
          part_number: number
          size?: number
          upload_id: string
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          etag?: string
          id?: string
          key?: string
          owner_id?: string | null
          part_number?: number
          size?: number
          upload_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_parts_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "s3_multipart_uploads_parts_upload_id_fkey"
            columns: ["upload_id"]
            isOneToOne: false
            referencedRelation: "s3_multipart_uploads"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      add_prefixes: {
        Args: { _bucket_id: string; _name: string }
        Returns: undefined
      }
      can_insert_object: {
        Args: { bucketid: string; name: string; owner: string; metadata: Json }
        Returns: undefined
      }
      delete_prefix: {
        Args: { _bucket_id: string; _name: string }
        Returns: boolean
      }
      extension: {
        Args: { name: string }
        Returns: string
      }
      filename: {
        Args: { name: string }
        Returns: string
      }
      foldername: {
        Args: { name: string }
        Returns: string[]
      }
      get_level: {
        Args: { name: string }
        Returns: number
      }
      get_prefix: {
        Args: { name: string }
        Returns: string
      }
      get_prefixes: {
        Args: { name: string }
        Returns: string[]
      }
      get_size_by_bucket: {
        Args: Record<PropertyKey, never>
        Returns: {
          size: number
          bucket_id: string
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          prefix_param: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
        }
        Returns: {
          key: string
          id: string
          created_at: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          bucket_id: string
          prefix_param: string
          delimiter_param: string
          max_keys?: number
          start_after?: string
          next_token?: string
        }
        Returns: {
          name: string
          id: string
          metadata: Json
          updated_at: string
        }[]
      }
      operation: {
        Args: Record<PropertyKey, never>
        Returns: string
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
      search_legacy_v1: {
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
      search_v1_optimised: {
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
      search_v2: {
        Args: {
          prefix: string
          bucket_name: string
          limits?: number
          levels?: number
          start_after?: string
        }
        Returns: {
          key: string
          name: string
          id: string
          updated_at: string
          created_at: string
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

type DefaultSchema = Database[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof (Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        Database[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? (Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      Database[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof Database },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof Database },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof Database }
  ? Database[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof Database },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof Database
  }
    ? keyof Database[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends { schema: keyof Database }
  ? Database[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      event_availability: ["busy", "away", "focus", "free", "location"],
      event_internal: ["internal", "external"],
      event_response: ["accepted", "declined", "tentative"],
      event_status: ["confirmed", "cancelled", "tentative"],
      event_type: ["meeting", "task", "note"],
      event_visibility: [
        "normal",
        "private",
        "confidential",
        "public",
        "personal",
      ],
      location_type: ["room", "address", "other"],
      meeting_size: ["1:1", "Small", "Medium", "Large", "XL", "XXL"],
      provider: ["google", "outlook"],
    },
  },
  storage: {
    Enums: {},
  },
} as const

