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
          created_at: string
          credentials: Json | null
          domain_id: number | null
          email: string | null
          id: number
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
          organization: unknown | null
        }
        Insert: {
          auth_user_id: string
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
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
            referencedColumns: ["user_id"]
          }
        ]
      }
      calendar: {
        Row: {
          account_id: number
          created_at: string
          ends_at: string | null
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          more: boolean | null
          next_token: string | null
          provider_id: string
          sequence: number
          starts_at: string | null
          sync_error: string | null
          synced_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
          accounts: unknown | null
        }
        Insert: {
          account_id: number
          created_at?: string
          ends_at?: string | null
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: number
          more?: boolean | null
          next_token?: string | null
          provider_id: string
          sequence?: number
          starts_at?: string | null
          sync_error?: string | null
          synced_at?: string | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Update: {
          account_id?: number
          created_at?: string
          ends_at?: string | null
          full_sync_at?: string | null
          full_sync_started_at?: string | null
          id?: number
          more?: boolean | null
          next_token?: string | null
          provider_id?: string
          sequence?: number
          starts_at?: string | null
          sync_error?: string | null
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
      contact: {
        Row: {
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
          contact_user_id?: number | null
          created_at?: string
          domain_id?: number | null
          email?: string | null
          id?: number
          name?: string | null
          user_id: number
        }
        Update: {
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
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "contact_contact_user_id_fkey"
            columns: ["contact_user_id"]
            referencedRelation: "expenditure_monthly"
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
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
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
          name: string | null
          organizer: number | null
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
          name?: string | null
          organizer?: number | null
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
          name?: string | null
          organizer?: number | null
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
          },
          {
            foreignKeyName: "event_organizer_fkey"
            columns: ["organizer"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          }
        ]
      }
      event_label: {
        Row: {
          created_at: string | null
          event_id: number | null
          id: number
          label_id: number
          negate: boolean
          priority: number
          series: string | null
        }
        Insert: {
          created_at?: string | null
          event_id?: number | null
          id?: number
          label_id: number
          negate?: boolean
          priority?: number
          series?: string | null
        }
        Update: {
          created_at?: string | null
          event_id?: number | null
          id?: number
          label_id?: number
          negate?: boolean
          priority?: number
          series?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "event_label_event_id_fkey"
            columns: ["event_id"]
            referencedRelation: "event"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_label_label_id_fkey"
            columns: ["label_id"]
            referencedRelation: "label"
            referencedColumns: ["id"]
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
          contact_id: number
          created_at: string
          event_id: number
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
          sequence: number
        }
        Insert: {
          contact_id: number
          created_at?: string
          event_id: number
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
          sequence?: number
        }
        Update: {
          contact_id?: number
          created_at?: string
          event_id?: number
          is_optional?: boolean
          response?: Database["public"]["Enums"]["event_response"] | null
          sequence?: number
        }
        Relationships: [
          {
            foreignKeyName: "invitee_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitee_event_id_fkey"
            columns: ["event_id"]
            referencedRelation: "event"
            referencedColumns: ["id"]
          }
        ]
      }
      label: {
        Row: {
          created_at: string | null
          description: string | null
          id: number
          name: string
          order: number
          tag: string | null
          user_id: number | null
        }
        Insert: {
          created_at?: string | null
          description?: string | null
          id?: number
          name: string
          order: number
          tag?: string | null
          user_id?: number | null
        }
        Update: {
          created_at?: string | null
          description?: string | null
          id?: number
          name?: string
          order?: number
          tag?: string | null
          user_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "label_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "label_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "label_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "label_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
            referencedColumns: ["user_id"]
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
          sequence: number
        }
        Insert: {
          calendar_id: number
          created_at?: string
          event: Json
          id?: number
          provider_id: string
          sequence?: number
        }
        Update: {
          calendar_id?: number
          created_at?: string
          event?: Json
          id?: number
          provider_id?: string
          sequence?: number
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
      response: {
        Row: {
          attendance: Database["public"]["Enums"]["event_attendance"] | null
          created_at: string | null
          id: number
          provider_id: string
          ready: boolean
          reviewed: boolean
          user_id: number
        }
        Insert: {
          attendance?: Database["public"]["Enums"]["event_attendance"] | null
          created_at?: string | null
          id?: number
          provider_id: string
          ready?: boolean
          reviewed?: boolean
          user_id: number
        }
        Update: {
          attendance?: Database["public"]["Enums"]["event_attendance"] | null
          created_at?: string | null
          id?: number
          provider_id?: string
          ready?: boolean
          reviewed?: boolean
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "response_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "response_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "response_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "response_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
            referencedColumns: ["user_id"]
          }
        ]
      }
      target: {
        Row: {
          created_at: string | null
          id: number
          label_id: number
          org: boolean
          target: number
          user_id: number
        }
        Insert: {
          created_at?: string | null
          id?: number
          label_id: number
          org?: boolean
          target: number
          user_id: number
        }
        Update: {
          created_at?: string | null
          id?: number
          label_id?: number
          org?: boolean
          target?: number
          user_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "target_label_id_fkey"
            columns: ["label_id"]
            referencedRelation: "label"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "target_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "target_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "target_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "target_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
            referencedColumns: ["user_id"]
          }
        ]
      }
      user: {
        Row: {
          avatar_url: string | null
          created_at: string
          email: string
          id: number
          invitation: string | null
          name: string
          timezone: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          email: string
          id?: number
          invitation?: string | null
          name: string
          timezone?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          email?: string
          id?: number
          invitation?: string | null
          name?: string
          timezone?: string
        }
        Relationships: []
      }
      waitlist: {
        Row: {
          created_at: string | null
          email: string
          id: number
          provider: Database["public"]["Enums"]["provider"] | null
          sync_error: string | null
          user_id: number | null
        }
        Insert: {
          created_at?: string | null
          email: string
          id?: number
          provider?: Database["public"]["Enums"]["provider"] | null
          sync_error?: string | null
          user_id?: number | null
        }
        Update: {
          created_at?: string | null
          email?: string
          id?: number
          provider?: Database["public"]["Enums"]["provider"] | null
          sync_error?: string | null
          user_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "waitlist_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "waitlist_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "event_x"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "waitlist_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "waitlist_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "expenditure_monthly"
            referencedColumns: ["user_id"]
          }
        ]
      }
    }
    Views: {
      event_x: {
        Row: {
          at: unknown | null
          attendance: Database["public"]["Enums"]["event_attendance"] | null
          attendee_count: number | null
          availability: Database["public"]["Enums"]["event_availability"] | null
          calendar_id: number | null
          conferencing_url: string | null
          created_at: string | null
          day: string | null
          description: string | null
          id: number | null
          initiated: boolean | null
          invitee_count: number | null
          minutes: number | null
          name: string | null
          organizer: number | null
          provider_id: string | null
          provider_link: string | null
          ready: boolean | null
          response: Database["public"]["Enums"]["event_response"] | null
          reviewed: boolean | null
          series: string | null
          status: Database["public"]["Enums"]["event_status"] | null
          summary: string | null
          user_id: number | null
          visibility: Database["public"]["Enums"]["event_visibility"] | null
        }
        Relationships: []
      }
      expenditure: {
        Row: {
          day: string | null
          event_count: number | null
          label_id: number | null
          minutes: number | null
          org_event_count: number | null
          org_minutes: number | null
          response: Database["public"]["Enums"]["event_response"] | null
          user_id: number | null
        }
        Relationships: [
          {
            foreignKeyName: "event_label_label_id_fkey"
            columns: ["label_id"]
            referencedRelation: "label"
            referencedColumns: ["id"]
          }
        ]
      }
      expenditure_monthly: {
        Row: {
          event_count: number | null
          label_id: number | null
          minutes: number | null
          month: string | null
          org_event_count: number | null
          org_minutes: number | null
          response: Database["public"]["Enums"]["event_response"] | null
          user_id: number | null
        }
        Relationships: [
          {
            foreignKeyName: "event_label_label_id_fkey"
            columns: ["label_id"]
            referencedRelation: "label"
            referencedColumns: ["id"]
          }
        ]
      }
      expenditure_rolling: {
        Row: {
          day: string | null
          event_count: number | null
          label_id: number | null
          minutes: number | null
          org_event_count: number | null
          org_minutes: number | null
          response: Database["public"]["Enums"]["event_response"] | null
          user_id: number | null
        }
        Relationships: []
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
          provider: Database["public"]["Enums"]["provider"] | null
          status: string | null
          sync_accounts: string[] | null
          sync_error: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      accounts: {
        Args: {
          "": unknown
        }
        Returns: {
          auth_user_id: string
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
      calc_attendance: {
        Args: {
          attendance: Database["public"]["Enums"]["event_attendance"]
          response: Database["public"]["Enums"]["event_response"]
          invitee_count: number
        }
        Returns: Database["public"]["Enums"]["event_attendance"]
      }
      calendars: {
        Args: {
          "": unknown
        }
        Returns: {
          account_id: number
          created_at: string
          ends_at: string | null
          full_sync_at: string | null
          full_sync_started_at: string | null
          id: number
          more: boolean | null
          next_token: string | null
          provider_id: string
          sequence: number
          starts_at: string | null
          sync_error: string | null
          synced_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
        }[]
      }
      get_or_create_domain_id: {
        Args: {
          email: string
        }
        Returns: number
      }
      insert_user: {
        Args: {
          _name: string
          _email: string
          _avatar_url: string
          _invitation: string
        }
        Returns: number
      }
      invitee: {
        Args: {
          "": unknown
        }
        Returns: {
          contact_id: number
          created_at: string
          event_id: number
          is_optional: boolean
          response: Database["public"]["Enums"]["event_response"] | null
          sequence: number
        }[]
      }
      is_user_account: {
        Args: {
          auth_user_id: string
          user_id: number
        }
        Returns: boolean
      }
      label:
        | {
            Args: {
              "": unknown
            }
            Returns: {
              created_at: string | null
              description: string | null
              id: number
              name: string
              order: number
              tag: string | null
              user_id: number | null
            }[]
          }
        | {
            Args: {
              "": unknown
            }
            Returns: {
              created_at: string | null
              description: string | null
              id: number
              name: string
              order: number
              tag: string | null
              user_id: number | null
            }[]
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
      upsert_event: {
        Args: {
          _calendar_id: number
          _raw_event: unknown
          _event: unknown
          _organizer: Database["public"]["CompositeTypes"]["event_contact"]
          _invitees: Database["public"]["CompositeTypes"]["event_invitee"][]
        }
        Returns: number
      }
    }
    Enums: {
      event_attendance: "attend" | "if-possible" | "skip"
      event_availability: "busy" | "away" | "focus" | "free"
      event_response: "accepted" | "declined" | "tentative"
      event_status: "confirmed" | "cancelled" | "tentative"
      event_visibility:
        | "normal"
        | "private"
        | "confidential"
        | "public"
        | "personal"
      location_type: "room" | "address" | "other"
      provider: "google" | "outlook"
    }
    CompositeTypes: {
      event_contact: {
        email: string
        name: string
      }
      event_invitee: {
        contact: Database["public"]["CompositeTypes"]["event_contact"]
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

