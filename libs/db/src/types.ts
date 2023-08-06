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
          email: string | null
          id: number
          organization_id: number | null
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
        }
        Insert: {
          auth_user_id: string
          created_at?: string
          credentials?: Json | null
          email?: string | null
          id?: number
          organization_id?: number | null
          provider: Database["public"]["Enums"]["provider"]
          user_id: number
        }
        Update: {
          auth_user_id?: string
          created_at?: string
          credentials?: Json | null
          email?: string | null
          id?: number
          organization_id?: number | null
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
            foreignKeyName: "account_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          }
        ]
      }
      calendar: {
        Row: {
          account_id: number
          created_at: string
          ends_at: string | null
          id: number
          more: boolean | null
          next_token: string | null
          provider_id: string
          sequence: number
          starts_at: string | null
          watch_expires_at: string | null
          watch_id: string | null
          watch_secret: string | null
        }
        Insert: {
          account_id: number
          created_at?: string
          ends_at?: string | null
          id?: number
          more?: boolean | null
          next_token?: string | null
          provider_id: string
          sequence?: number
          starts_at?: string | null
          watch_expires_at?: string | null
          watch_id?: string | null
          watch_secret?: string | null
        }
        Update: {
          account_id?: number
          created_at?: string
          ends_at?: string | null
          id?: number
          more?: boolean | null
          next_token?: string | null
          provider_id?: string
          sequence?: number
          starts_at?: string | null
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
          email: string | null
          id: number
          name: string | null
          organization_id: number | null
          user_id: number
        }
        Insert: {
          contact_user_id?: number | null
          created_at?: string
          email?: string | null
          id?: number
          name?: string | null
          organization_id?: number | null
          user_id: number
        }
        Update: {
          contact_user_id?: number | null
          created_at?: string
          email?: string | null
          id?: number
          name?: string | null
          organization_id?: number | null
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
            foreignKeyName: "contact_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
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
        Relationships: []
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
      user: {
        Row: {
          avatar_url: string | null
          created_at: string
          email: string
          id: number
          name: string
          timezone: string | null
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          email: string
          id?: number
          name: string
          timezone?: string | null
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          email?: string
          id?: number
          name?: string
          timezone?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      get_or_create_organization_id: {
        Args: {
          email: string
        }
        Returns: number
      }
      is_user_account: {
        Args: {
          auth_user_id: string
          account_id: number
        }
        Returns: boolean
      }
      upsert_event: {
        Args: {
          _calendar_id: number
          _raw_event: unknown
          _event: unknown
          _organizer: Database["public"]["CompositeTypes"]["event_contact"]
          _invitees: Database["public"]["CompositeTypes"]["event_invitee"][]
        }
        Returns: undefined
      }
    }
    Enums: {
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

