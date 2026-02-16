export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      activity: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string
          created_at: string
          created_by: string
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean
          duration: unknown | null
          embedding: unknown | null
          id: string
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          meta: Json | null
          on: unknown | null
          order: number
          pick_priority: Json | null
          preview: string | null
          priority_id: string
          private: boolean
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string
          source_priority_root: unknown | null
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
          actor: unknown | null
          assignee: unknown | null
        }
        Insert: {
          archived_at?: string | null
          assignee_id?: string | null
          at?: unknown | null
          author_id: string
          created_at?: string
          created_by: string
          created_by_twist_id?: number | null
          done_at?: string | null
          draft?: boolean
          duration?: unknown | null
          embedding?: unknown | null
          id?: string
          kind?: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          meta?: Json | null
          on?: unknown | null
          order?: number
          pick_priority?: Json | null
          preview?: string | null
          priority_id: string
          private?: boolean
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown | null
          sync_depth?: number | null
          title?: string | null
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
          updated_by?: number
        }
        Update: {
          archived_at?: string | null
          assignee_id?: string | null
          at?: unknown | null
          author_id?: string
          created_at?: string
          created_by?: string
          created_by_twist_id?: number | null
          done_at?: string | null
          draft?: boolean
          duration?: unknown | null
          embedding?: unknown | null
          id?: string
          kind?: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          meta?: Json | null
          on?: unknown | null
          order?: number
          pick_priority?: Json | null
          preview?: string | null
          priority_id?: string
          private?: boolean
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown | null
          sync_depth?: number | null
          title?: string | null
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      activity_exception: {
        Row: {
          activity_id: string
          archived_at: string | null
          at: unknown | null
          created_at: string
          done_at: string | null
          duration: unknown | null
          id: string
          meta: Json | null
          occurrence: string
          on: unknown | null
          preview: string | null
          title: string | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          activity_id: string
          archived_at?: string | null
          at?: unknown | null
          created_at?: string
          done_at?: string | null
          duration?: unknown | null
          id?: string
          meta?: Json | null
          occurrence: string
          on?: unknown | null
          preview?: string | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          archived_at?: string | null
          at?: unknown | null
          created_at?: string
          done_at?: string | null
          duration?: unknown | null
          id?: string
          meta?: Json | null
          occurrence?: string
          on?: unknown | null
          preview?: string | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_read: {
        Row: {
          activity_id: string
          read_at: string
          updated_at: string
          user_id: string
        }
        Insert: {
          activity_id: string
          read_at?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          activity_id?: string
          read_at?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "activity_read_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_read_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_read_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_read_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_read_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_tag: {
        Row: {
          activity_id: string
          actor_id: string
          archived_at: string | null
          id: number
          occurrence: string | null
          sync_depth: number | null
          tag_id: number
          updated_at: string
          updated_by: number
        }
        Insert: {
          activity_id: string
          actor_id: string
          archived_at?: string | null
          id?: never
          occurrence?: string | null
          sync_depth?: number | null
          tag_id: number
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          actor_id?: string
          archived_at?: string | null
          id?: never
          occurrence?: string | null
          sync_depth?: number | null
          tag_id?: number
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
        ]
      }
      contact: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string
          email: string
          id: string
          name: string | null
          primary: boolean
          updated_at: string
          user_id: string | null
          organization: unknown | null
        }
        Insert: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          email: string
          id?: string
          name?: string | null
          primary?: boolean
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          email?: string
          id?: string
          name?: string | null
          primary?: boolean
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contact_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      contact_external_account: {
        Row: {
          account_id: string
          contact_id: string
          data_fetched_at: string
          last_reported_at: string | null
          provider: string
        }
        Insert: {
          account_id: string
          contact_id: string
          data_fetched_at?: string
          last_reported_at?: string | null
          provider: string
        }
        Update: {
          account_id?: string
          contact_id?: string
          data_fetched_at?: string
          last_reported_at?: string | null
          provider?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_external_account_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
        ]
      }
      contact_invitation: {
        Row: {
          contact_id: string
          created_at: string
          id: number
          redeemed_at: string | null
          redeemed_by: string | null
          sent_at: string
          token: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          id?: never
          redeemed_at?: string | null
          redeemed_by?: string | null
          sent_at?: string
          token: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          id?: never
          redeemed_at?: string | null
          redeemed_by?: string | null
          sent_at?: string
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_invitation_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: true
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_invitation_redeemed_by_fkey"
            columns: ["redeemed_by"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      cost: {
        Row: {
          amount: number | null
          created_at: string
          id: number
          name: string
          start: string
          updated_at: string
        }
        Insert: {
          amount?: number | null
          created_at?: string
          id?: never
          name: string
          start: string
          updated_at?: string
        }
        Update: {
          amount?: number | null
          created_at?: string
          id?: never
          name?: string
          start?: string
          updated_at?: string
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
      note: {
        Row: {
          activity_id: string
          archived_at: string | null
          author_id: string
          content: string | null
          created_at: string
          created_by: string
          draft: boolean
          id: string
          key: string | null
          links: Json | null
          mentions: string[] | null
          private: boolean
          re_note_id: string | null
          source_created_at: string
          sync_depth: number | null
          updated_at: string
          updated_by: number
          actor: unknown | null
        }
        Insert: {
          activity_id: string
          archived_at?: string | null
          author_id: string
          content?: string | null
          created_at?: string
          created_by: string
          draft?: boolean
          id?: string
          key?: string | null
          links?: Json | null
          mentions?: string[] | null
          private?: boolean
          re_note_id?: string | null
          source_created_at?: string
          sync_depth?: number | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          archived_at?: string | null
          author_id?: string
          content?: string | null
          created_at?: string
          created_by?: string
          draft?: boolean
          id?: string
          key?: string | null
          links?: Json | null
          mentions?: string[] | null
          private?: boolean
          re_note_id?: string | null
          source_created_at?: string
          sync_depth?: number | null
          updated_at?: string
          updated_by?: number
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
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
        ]
      }
      note_tag: {
        Row: {
          actor_id: string
          archived_at: string | null
          id: number
          note_id: string
          sync_depth: number | null
          tag_id: number
          updated_at: string
          updated_by: number
        }
        Insert: {
          actor_id: string
          archived_at?: string | null
          id?: never
          note_id: string
          sync_depth?: number | null
          tag_id: number
          updated_at?: string
          updated_by?: number
        }
        Update: {
          actor_id?: string
          archived_at?: string | null
          id?: never
          note_id?: string
          sync_depth?: number | null
          tag_id?: number
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "note_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_update"
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
          archived_at: string | null
          color: number | null
          created_at: string
          created_by: string
          id: string
          key: string | null
          path: unknown
          sync_depth: number | null
          title: string
          updated_at: string
          updated_by: number
        }
        Insert: {
          archived_at?: string | null
          color?: number | null
          created_at?: string
          created_by: string
          id?: string
          key?: string | null
          path: unknown
          sync_depth?: number | null
          title: string
          updated_at?: string
          updated_by?: number
        }
        Update: {
          archived_at?: string | null
          color?: number | null
          created_at?: string
          created_by?: string
          id?: string
          key?: string | null
          path?: unknown
          sync_depth?: number | null
          title?: string
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "priority_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_contact: {
        Row: {
          contact_id: string
          created_at: string
          id: number
          invited_at: string | null
          invited_by: string | null
          priority_id: string
          updated_at: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          id?: never
          invited_at?: string | null
          invited_by?: string | null
          priority_id: string
          updated_at?: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          id?: never
          invited_at?: string | null
          invited_by?: string | null
          priority_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_contact_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_settings: {
        Row: {
          color: number | null
          order: number | null
          path: unknown | null
          pomodoro: number | null
          priority_id: string
          title: string | null
          top_order: number | null
          updated_at: string
          user_id: string
        }
        Insert: {
          color?: number | null
          order?: number | null
          path?: unknown | null
          pomodoro?: number | null
          priority_id: string
          title?: string | null
          top_order?: number | null
          updated_at?: string
          user_id: string
        }
        Update: {
          color?: number | null
          order?: number | null
          path?: unknown | null
          pomodoro?: number | null
          priority_id?: string
          title?: string | null
          top_order?: number | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist: {
        Row: {
          archived_at: string | null
          config: Json
          created_at: string
          id: string
          name: string
          owner_id: string
          priority_id: string
          suspended_at: string | null
          twist_id: number
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          config?: Json
          created_at?: string
          id?: string
          name: string
          owner_id: string
          priority_id: string
          suspended_at?: string | null
          twist_id: number
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          config?: Json
          created_at?: string
          id?: string
          name?: string
          owner_id?: string
          priority_id?: string
          suspended_at?: string | null
          twist_id?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_twist_id_fkey"
            columns: ["twist_id"]
            isOneToOne: false
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_sync: {
        Row: {
          entity: string
          last_sync_at: string
          last_update_at: string
          operation: Database["public"]["Enums"]["sync_operation"]
          priority_twist_id: string
        }
        Insert: {
          entity: string
          last_sync_at?: string
          last_update_at: string
          operation: Database["public"]["Enums"]["sync_operation"]
          priority_twist_id: string
        }
        Update: {
          entity?: string
          last_sync_at?: string
          last_update_at?: string
          operation?: Database["public"]["Enums"]["sync_operation"]
          priority_twist_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["priority_twist_id"]
          },
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["priority_twist_id"]
          },
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_user: {
        Row: {
          archived_at: string | null
          created_at: string
          personal: boolean
          priority_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          personal?: boolean
          priority_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          personal?: boolean
          priority_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      publisher: {
        Row: {
          created_at: string
          email: string | null
          id: number
          name: string
          updated_at: string
          url: string | null
        }
        Insert: {
          created_at?: string
          email?: string | null
          id?: never
          name: string
          updated_at?: string
          url?: string | null
        }
        Update: {
          created_at?: string
          email?: string | null
          id?: never
          name?: string
          updated_at?: string
          url?: string | null
        }
        Relationships: []
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
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
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      session: {
        Row: {
          archived_at: string | null
          at: unknown
          created_at: string
          id: string
          pomodoro: number | null
          pomodoro_at: string | null
          precedence: number
          priority_id: string | null
          updated_at: string
          updated_by: number
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          at: unknown
          created_at?: string
          id?: string
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          updated_at?: string
          updated_by?: number
          user_id: string
        }
        Update: {
          archived_at?: string | null
          at?: unknown
          created_at?: string
          id?: string
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          updated_at?: string
          updated_by?: number
          user_id?: string
        }
        Relationships: [
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      token: {
        Row: {
          archived_at: string | null
          created_at: string
          id: string
          last_used_at: string | null
          name: string | null
          publisher_id: number | null
          token: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          id?: string
          last_used_at?: string | null
          name?: string | null
          publisher_id?: number | null
          token: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          id?: string
          last_used_at?: string | null
          name?: string | null
          publisher_id?: number | null
          token?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "token_publisher_id_fkey"
            columns: ["publisher_id"]
            isOneToOne: false
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "token_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist: {
        Row: {
          archived_at: string | null
          created_at: string
          description: string | null
          environment: Database["public"]["Enums"]["twist_environment"]
          id: number
          name: string
          permissions: Json | null
          twist_admin_id: number
          updated_at: string
          version: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          id?: never
          name: string
          permissions?: Json | null
          twist_admin_id: number
          updated_at?: string
          version: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          id?: never
          name?: string
          permissions?: Json | null
          twist_admin_id?: number
          updated_at?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_twist_admin_id_fkey"
            columns: ["twist_admin_id"]
            isOneToOne: false
            referencedRelation: "twist_admin"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_admin: {
        Row: {
          auto_approve: boolean
          created_at: string
          id: number
          priority_id: string | null
          publisher_id: number | null
          twist_package_id: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          auto_approve?: boolean
          created_at?: string
          id?: never
          priority_id?: string | null
          publisher_id?: number | null
          twist_package_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          auto_approve?: boolean
          created_at?: string
          id?: never
          priority_id?: string | null
          publisher_id?: number | null
          twist_package_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_publisher_id_fkey"
            columns: ["publisher_id"]
            isOneToOne: false
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      usage: {
        Row: {
          amount: number
          cost_id: number
          created_at: string
          hour: string
          id: number
          priority_twist_id: string
          updated_at: string
        }
        Insert: {
          amount: number
          cost_id: number
          created_at?: string
          hour: string
          id?: never
          priority_twist_id: string
          updated_at?: string
        }
        Update: {
          amount?: number
          cost_id?: number
          created_at?: string
          hour?: string
          id?: never
          priority_twist_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "usage_cost_id_fkey"
            columns: ["cost_id"]
            isOneToOne: false
            referencedRelation: "cost"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["priority_twist_id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["priority_twist_id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            isOneToOne: false
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      user: {
        Row: {
          avatar_url: string | null
          clerk_id: string | null
          created_at: string
          email: string
          id: string
          name: string | null
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          clerk_id?: string | null
          created_at?: string
          email: string
          id?: string
          name?: string | null
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          clerk_id?: string | null
          created_at?: string
          email?: string
          id?: string
          name?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      user_settings: {
        Row: {
          enter_behavior: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at: string
          user_id: string
        }
        Insert: {
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at?: string
          user_id: string
        }
        Update: {
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_settings_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      user_subscription: {
        Row: {
          billing_cycle_end: string
          billing_cycle_start: string
          created_at: string
          id: number
          plan: Database["public"]["Enums"]["subscription_plan"]
          status: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          billing_cycle_end: string
          billing_cycle_start: string
          created_at?: string
          id?: never
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          billing_cycle_end?: string
          billing_cycle_start?: string
          created_at?: string
          id?: never
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_subscription_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      user_sync: {
        Row: {
          entity: string
          last_sync_at: string
          last_update_at: string
          user_id: string
        }
        Insert: {
          entity: string
          last_sync_at?: string
          last_update_at: string
          user_id: string
        }
        Update: {
          entity?: string
          last_sync_at?: string
          last_update_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_sync_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      activity_tags: {
        Row: {
          activity_id: string | null
          occurrence: string | null
          tags: Json | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_x: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string | null
          created_at: string | null
          created_by: string | null
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean | null
          duration: unknown | null
          embedding: unknown | null
          id: string | null
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown | null
          order: number | null
          pick_priority: Json | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown | null
          private: boolean | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string | null
          source_priority_root: unknown | null
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      actor: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string | null
          email: string | null
          id: string | null
          name: string | null
          type: string | null
          updated_at: string | null
        }
        Relationships: []
      }
      note_tags: {
        Row: {
          note_id: string | null
          tags: Json | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "note_tags"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_child: {
        Row: {
          archived_at: string | null
          child_id: string | null
          priority_id: string | null
        }
        Relationships: []
      }
      priority_child_twist: {
        Row: {
          archived_at: string | null
          author_email: string | null
          author_name: string | null
          author_url: string | null
          config: Json | null
          created_at: string | null
          id: string | null
          name: string | null
          owner_id: string | null
          priority_child_id: string | null
          priority_id: string | null
          suspended_at: string | null
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          version: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_twist_id_fkey"
            columns: ["twist_id"]
            isOneToOne: false
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_member: {
        Row: {
          archived_at: string | null
          contact_id: string | null
          created_at: string | null
          invited_by: string | null
          personal: boolean | null
          priority_id: string | null
          status: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_contact_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_settings_inherited: {
        Row: {
          color: number | null
          path: unknown | null
          pomodoro: number | null
          priority_id: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority_tags: {
        Row: {
          count: number | null
          priority_id: string | null
          tag_id: number | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_twist_activity_create: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          created_at: string | null
          created_by: string | null
          done_at: string | null
          draft: boolean | null
          duration: unknown | null
          id: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown | null
          order: number | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          private: boolean | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_twist_activity_tag_change: {
        Row: {
          activity_id: string | null
          actor_id: string | null
          change_type: string | null
          occurrence: string | null
          priority_twist_id: string | null
          tag_id: number | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_activity_update: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          created_at: string | null
          created_by: string | null
          done_at: string | null
          draft: boolean | null
          duration: unknown | null
          id: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown | null
          order: number | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          private: boolean | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_twist_note_create: {
        Row: {
          activity_created_by: string | null
          activity_id: string | null
          activity_mentions: string[] | null
          activity_meta: Json | null
          activity_title: string | null
          archived_at: string | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          content: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          first_mentioned_at: string | null
          id: string | null
          key: string | null
          links: Json | null
          mentions: string[] | null
          priority_id: string | null
          priority_twist_id: string | null
          private: boolean | null
          re_note_id: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
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
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note_tags"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_note_update: {
        Row: {
          activity_created_by: string | null
          activity_id: string | null
          activity_mentions: string[] | null
          activity_meta: Json | null
          activity_title: string | null
          archived_at: string | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          content: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          id: string | null
          key: string | null
          links: Json | null
          mentions: string[] | null
          priority_id: string | null
          priority_twist_id: string | null
          private: boolean | null
          re_note_id: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
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
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            isOneToOne: false
            referencedRelation: "note_tags"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _ltree_compress: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      _ltree_gist_options: {
        Args: {
          "": unknown
        }
        Returns: undefined
      }
      activate_invited_user: {
        Args: {
          p_user_id: string
        }
        Returns: Json
      }
      actor:
        | {
            Args: {
              "": unknown
            }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }[]
          }
        | {
            Args: {
              "": unknown
            }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }[]
          }
        | {
            Args: {
              "": unknown
            }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }[]
          }
        | {
            Args: {
              "": unknown
            }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }[]
          }
      assignee: {
        Args: {
          "": unknown
        }
        Returns: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string | null
          email: string | null
          id: string | null
          name: string | null
          type: string | null
          updated_at: string | null
        }[]
      }
      binary_quantize:
        | {
            Args: {
              "": string
            }
            Returns: unknown
          }
        | {
            Args: {
              "": unknown
            }
            Returns: unknown
          }
      count_not_null: {
        Args: {
          val: unknown
        }
        Returns: number
      }
      find_matching_activities_scored: {
        Args: {
          query_embedding: string
          created_by_id: string
          required_filters?: Json
          scored_fields?: Json
          activity_data?: Json
          similarity_threshold?: number
        }
        Returns: {
          id: string
          priority_id: string
          title: string
          total_score: number
        }[]
      }
      find_similar_activities: {
        Args: {
          query_embedding: string
          match_limit?: number
          similarity_threshold?: number
          created_by_id: string
        }
        Returns: {
          title: string
          priority_id: string
          id: string
          similarity: number
        }[]
      }
      generate_path: {
        Args: {
          parent?: unknown
        }
        Returns: unknown
      }
      get_accessible_twists: {
        Args: {
          p_user_id: string
          p_priority_id: string
        }
        Returns: {
          archived_at: string | null
          created_at: string
          description: string | null
          environment: Database["public"]["Enums"]["twist_environment"]
          id: number
          name: string
          permissions: Json | null
          twist_admin_id: number
          updated_at: string
          version: string
        }[]
      }
      get_activity_mentions: {
        Args: {
          p_activity_id: string
        }
        Returns: string[]
      }
      get_domain: {
        Args: {
          email: string
        }
        Returns: string
      }
      get_invitation_token: {
        Args: {
          p_contact_id: string
          p_new_token: string
        }
        Returns: Json
      }
      get_pending_user_sync: {
        Args: {
          p_user_id: string
        }
        Returns: {
          entity: string
          last_update_at: string
        }[]
      }
      get_primary_contact_id: {
        Args: {
          p_user_id: string
        }
        Returns: string
      }
      get_priority_twist_owner_contact: {
        Args: {
          p_priority_twist_id: string
        }
        Returns: string
      }
      get_stale_twist_syncs: {
        Args: {
          p_limit?: number
          p_stale_threshold: string
        }
        Returns: {
          priority_twist_id: string
        }[]
      }
      get_stale_user_syncs: {
        Args: {
          p_limit?: number
          p_stale_threshold: string
        }
        Returns: {
          user_id: string
        }[]
      }
      get_tag_type: {
        Args: {
          tag_id: number
        }
        Returns: Database["public"]["Enums"]["tag_type"]
      }
      get_users_with_priority_access: {
        Args: {
          target_priority_id: string
        }
        Returns: {
          user_id: string
        }[]
      }
      halfvec_avg: {
        Args: {
          "": number[]
        }
        Returns: unknown
      }
      halfvec_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      halfvec_send: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      halfvec_typmod_in: {
        Args: {
          "": unknown[]
        }
        Returns: number
      }
      hash_ltree: {
        Args: {
          "": unknown
        }
        Returns: number
      }
      hnsw_bit_support: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      hnsw_halfvec_support: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      hnsw_sparsevec_support: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      hnswhandler: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      insert_domain: {
        Args: {
          email: string
        }
        Returns: number
      }
      is_accessible_twist: {
        Args: {
          p_twist_id: number
          p_priority_id: string
          p_user_id: string
        }
        Returns: boolean
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
      is_rsvp_tag: {
        Args: {
          tag_id: number
        }
        Returns: boolean
      }
      ivfflat_bit_support: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ivfflat_halfvec_support: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ivfflathandler: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      l2_norm:
        | {
            Args: {
              "": unknown
            }
            Returns: number
          }
        | {
            Args: {
              "": unknown
            }
            Returns: number
          }
      l2_normalize:
        | {
            Args: {
              "": string
            }
            Returns: string
          }
        | {
            Args: {
              "": unknown
            }
            Returns: unknown
          }
        | {
            Args: {
              "": unknown
            }
            Returns: unknown
          }
      lca: {
        Args: {
          "": unknown[]
        }
        Returns: unknown
      }
      lquery_in: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      lquery_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      lquery_recv: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      lquery_send: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      ltree_compress: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_decompress: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_gist_in: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_gist_options: {
        Args: {
          "": unknown
        }
        Returns: undefined
      }
      ltree_gist_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_in: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_recv: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltree_send: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      ltree2text: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      ltxtq_in: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltxtq_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltxtq_recv: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      ltxtq_send: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      move_priority: {
        Args: {
          p_priority_id: string
          p_new_parent_path: unknown
        }
        Returns: undefined
      }
      nlevel: {
        Args: {
          "": unknown
        }
        Returns: number
      }
      order_first: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      organization: {
        Args: {
          "": unknown
        }
        Returns: {
          created_at: string
          id: number
          name: string
        }[]
      }
      parent_path: {
        Args: {
          p: unknown
        }
        Returns: unknown
      }
      redeem_invitation_token: {
        Args: {
          p_token: string
          p_user_id: string
        }
        Returns: Json
      }
      setup_help_feedback_priority: {
        Args: {
          p_user_name?: string
          p_user_id?: string
        }
        Returns: Json
      }
      share_priority: {
        Args: {
          p_add_actor_ids: string[]
          p_priority_id: string
          p_user_id: string
          p_remove_actor_ids: string[]
        }
        Returns: Json
      }
      sparsevec_out: {
        Args: {
          "": unknown
        }
        Returns: unknown
      }
      sparsevec_send: {
        Args: {
          "": unknown
        }
        Returns: string
      }
      sparsevec_typmod_in: {
        Args: {
          "": unknown[]
        }
        Returns: number
      }
      sync_user_on_connect: {
        Args: {
          p_user_id: string
        }
        Returns: undefined
      }
      text2ltree: {
        Args: {
          "": string
        }
        Returns: unknown
      }
      tstzrange_to_daterange: {
        Args: {
          p_range: unknown
          p_timezone?: string
        }
        Returns: unknown
      }
      update_invitation_sent_at: {
        Args: {
          p_contact_id: string
        }
        Returns: undefined
      }
      updated_by_uuid: {
        Args: {
          id: string
        }
        Returns: number
      }
      upsert_contacts:
        | {
            Args: {
              _contacts: Database["public"]["CompositeTypes"]["contact_upsert"][]
            }
            Returns: undefined
          }
        | {
            Args: {
              contacts: Json
            }
            Returns: {
              user_id: string
              email: string
              id: string
              name: string
            }[]
          }
      upsert_user_contact: {
        Args: {
          user_email: string
          user_id: string
          avatar_url: string
          user_name: string
        }
        Returns: string
      }
      user_has_priority_access: {
        Args: {
          p_priority_id: string
          p_user_id: string
        }
        Returns: boolean
      }
      uuid_generate_v1: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_generate_v1mc: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_generate_v3: {
        Args: {
          name: string
          namespace: string
        }
        Returns: string
      }
      uuid_generate_v4: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_generate_v5: {
        Args: {
          name: string
          namespace: string
        }
        Returns: string
      }
      uuid_nil: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_ns_dns: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_ns_oid: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_ns_url: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_ns_x500: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      vector_avg: {
        Args: {
          "": number[]
        }
        Returns: string
      }
      vector_dims:
        | {
            Args: {
              "": string
            }
            Returns: number
          }
        | {
            Args: {
              "": unknown
            }
            Returns: number
          }
      vector_norm: {
        Args: {
          "": string
        }
        Returns: number
      }
      vector_out: {
        Args: {
          "": string
        }
        Returns: unknown
      }
      vector_send: {
        Args: {
          "": string
        }
        Returns: string
      }
      vector_typmod_in: {
        Args: {
          "": unknown[]
        }
        Returns: number
      }
      week_from_date: {
        Args: {
          d: string
        }
        Returns: unknown
      }
    }
    Enums: {
      activity_kind:
        | "document"
        | "messages"
        | "meeting"
        | "videoconference"
        | "phone"
        | "focus"
        | "meal"
        | "exercise"
        | "family"
        | "travel"
        | "social"
        | "entertainment"
      activity_type: "action" | "event" | "note"
      enter_behavior: "enter_newline" | "enter_submits"
      subscription_plan: "free"
      subscription_status:
        | "active"
        | "canceled"
        | "past_due"
        | "trialing"
        | "incomplete"
        | "incomplete_expired"
        | "unpaid"
      sync_operation: "create" | "update"
      tag_type: "toggle" | "count" | "compute"
      twist_environment: "personal" | "private" | "review" | "public"
    }
    CompositeTypes: {
      contact_upsert: {
        calendar_id: number | null
        email: string | null
        name: string | null
        avatar_url: string | null
      }
    }
  }
  user: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      activity: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string | null
          created_at: string | null
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean | null
          duration: unknown | null
          id: string | null
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown | null
          order: number | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown | null
          private: boolean | null
          range_at: unknown | null
          range_on: unknown | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: []
      }
      activity_exception: {
        Row: {
          activity_id: string | null
          archived_at: string | null
          at: unknown | null
          id: string | null
          occurrence: string | null
          on: unknown | null
          preview: string | null
          priority_path: unknown | null
          range_at: unknown | null
          range_on: unknown | null
          title: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "priority_twist_activity_update"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          occurrence: string | null
          priority_path: unknown | null
          range_at: unknown | null
          range_on: unknown | null
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      actor: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string | null
          email: string | null
          id: string | null
          name: string | null
          self: boolean | null
          type: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      note: {
        Row: {
          activity_id: string | null
          archived_at: string | null
          author_id: string | null
          content: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          id: string | null
          links: Json | null
          mentions: string[] | null
          private: boolean | null
          re_note_id: string | null
          source_created_at: string | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: []
      }
      note_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          priority_path: unknown | null
          range_at: unknown | null
          range_on: unknown | null
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority: {
        Row: {
          archived_at: string | null
          color: number | null
          created_at: string | null
          created_by: string | null
          global_path: unknown | null
          id: string | null
          key: string | null
          order: number | null
          path: unknown | null
          personal: boolean | null
          pomodoro: number | null
          root: boolean | null
          title: string | null
          top_order: number | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_actor: {
        Row: {
          actor_id: string | null
          archived_at: string | null
          created_at: string | null
          priority_path: unknown | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority_expanded: {
        Row: {
          archived_at: string | null
          joined_at: string | null
          path: unknown | null
          priority_id: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_unread: {
        Row: {
          priority_id: string | null
          unread: boolean | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist: {
        Row: {
          archived_at: string | null
          config: Json | null
          created_at: string | null
          id: string | null
          name: string | null
          owner_id: string | null
          priority_id: string | null
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_twist_id_fkey"
            columns: ["twist_id"]
            isOneToOne: false
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      assert_priority_access: {
        Args: {
          user_id: string
          priority_id: string
        }
        Returns: undefined
      }
      delete_activity_read: {
        Args: {
          user_id: string
          p_activity_id: string
        }
        Returns: undefined
      }
      has_priority_access: {
        Args: {
          priority_id: string
          user_id: string
        }
        Returns: boolean
      }
      mentioned_in_activity: {
        Args: {
          user_id: string
          activity_id: string
        }
        Returns: boolean
      }
      update_activity_tags: {
        Args: {
          p_activity_id: string
          p_client_id: number
          p_tag_updates: Json
          p_occurrence?: string
          p_actor_id: string
          user_id: string
        }
        Returns: undefined
      }
      update_note_tags: {
        Args: {
          p_note_id: string
          p_client_id: number
          p_tag_updates: Json
          p_actor_id: string
          user_id: string
        }
        Returns: undefined
      }
      upsert_activity: {
        Args: {
          p_defaults?: Json
          user_id: string
          p_activity: Json
        }
        Returns: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown | null
          author_id: string
          created_at: string
          created_by: string
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean
          duration: unknown | null
          embedding: unknown | null
          id: string
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          meta: Json | null
          on: unknown | null
          order: number
          pick_priority: Json | null
          preview: string | null
          priority_id: string
          private: boolean
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string
          source_priority_root: unknown | null
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
        }
      }
      upsert_activity_exception: {
        Args: {
          p_title?: string
          user_id: string
          p_id: string
          p_activity_id: string
          p_occurrence: string
          p_archived_at?: string
          p_updated_by?: number
          p_at?: unknown
          p_on?: unknown
          p_duration?: unknown
          p_done_at?: string
          p_preview?: string
          p_meta?: Json
        }
        Returns: {
          activity_id: string
          archived_at: string | null
          at: unknown | null
          created_at: string
          done_at: string | null
          duration: unknown | null
          id: string
          meta: Json | null
          occurrence: string
          on: unknown | null
          preview: string | null
          title: string | null
          updated_at: string
          updated_by: number
        }
      }
      upsert_activity_read: {
        Args: {
          user_id: string
          p_activity_id: string
          p_read_at: string
        }
        Returns: {
          activity_id: string
          read_at: string
          updated_at: string
          user_id: string
        }
      }
      upsert_activity_tag: {
        Args: {
          p_tag_id: number
          p_occurrence?: string
          user_id: string
          p_archived_at?: string
          p_updated_by?: number
          p_actor_id: string
          p_activity_id: string
        }
        Returns: {
          activity_id: string
          actor_id: string
          archived_at: string | null
          id: number
          occurrence: string | null
          sync_depth: number | null
          tag_id: number
          updated_at: string
          updated_by: number
        }
      }
      upsert_note: {
        Args: {
          p_id: string
          p_author_id: string
          p_created_by: string
          p_archived_at: string
          p_draft: boolean
          p_private: boolean
          p_content: string
          p_links: Json
          p_mentions: string[]
          p_re_note_id: string
          p_source_created_at: string
          p_key: string
          user_id: string
          p_updated_by: number
          p_activity_id: string
        }
        Returns: {
          activity_id: string
          archived_at: string | null
          author_id: string
          content: string | null
          created_at: string
          created_by: string
          draft: boolean
          id: string
          key: string | null
          links: Json | null
          mentions: string[] | null
          private: boolean
          re_note_id: string | null
          source_created_at: string
          sync_depth: number | null
          updated_at: string
          updated_by: number
        }
      }
      upsert_note_tag: {
        Args: {
          p_archived_at?: string
          p_updated_by?: number
          p_tag_id: number
          p_note_id: string
          p_actor_id: string
          user_id: string
        }
        Returns: {
          actor_id: string
          archived_at: string | null
          id: number
          note_id: string
          sync_depth: number | null
          tag_id: number
          updated_at: string
          updated_by: number
        }
      }
      upsert_priority: {
        Args: {
          p_priority: Json
          user_id: string
        }
        Returns: {
          archived_at: string | null
          color: number | null
          created_at: string | null
          created_by: string | null
          global_path: unknown | null
          id: string | null
          key: string | null
          order: number | null
          path: unknown | null
          personal: boolean | null
          pomodoro: number | null
          root: boolean | null
          title: string | null
          top_order: number | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
      }
      upsert_priority_member: {
        Args: {
          user_id: string
          p_contact_id: string
          p_priority_id: string
          p_invited_by: string
          p_invited_at: string
        }
        Returns: {
          archived_at: string | null
          contact_id: string | null
          created_at: string | null
          invited_by: string | null
          personal: boolean | null
          priority_id: string | null
          status: string | null
          updated_at: string | null
        }
      }
      upsert_priority_twist: {
        Args: {
          p_name: string
          p_owner_id: string
          p_twist_id: number
          p_priority_id: string
          p_id: string
          user_id: string
          p_archived_at: string
          p_config: Json
        }
        Returns: {
          archived_at: string | null
          config: Json
          created_at: string
          id: string
          name: string
          owner_id: string
          priority_id: string
          suspended_at: string | null
          twist_id: number
          updated_at: string
        }
      }
      upsert_priority_user: {
        Args: {
          p_priority_id: string
          p_archived_at: string
          p_personal: boolean
          user_id: string
        }
        Returns: {
          archived_at: string | null
          created_at: string
          personal: boolean
          priority_id: string
          updated_at: string
          user_id: string
        }
      }
      upsert_session: {
        Args: {
          p_precedence: number
          p_pomodoro_at: string
          p_pomodoro: number
          p_archived_at: string
          p_updated_by: number
          user_id: string
          p_id: string
          p_priority_id: string
          p_at: unknown
        }
        Returns: {
          archived_at: string | null
          at: unknown
          created_at: string
          id: string
          pomodoro: number | null
          pomodoro_at: string | null
          precedence: number
          priority_id: string | null
          updated_at: string
          updated_by: number
          user_id: string
        }
      }
      upsert_user_settings: {
        Args: {
          user_id: string
          p_enter_behavior: Database["public"]["Enums"]["enter_behavior"]
        }
        Returns: {
          enter_behavior: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at: string
          user_id: string
        }
      }
      user_contact_id: {
        Args: {
          p_user_id: string
        }
        Returns: string
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

type PublicSchema = Database[Extract<keyof Database, "public">]

export type Tables<
  PublicTableNameOrOptions extends
    | keyof (PublicSchema["Tables"] & PublicSchema["Views"])
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
        Database[PublicTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? (Database[PublicTableNameOrOptions["schema"]]["Tables"] &
      Database[PublicTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : PublicTableNameOrOptions extends keyof (PublicSchema["Tables"] &
        PublicSchema["Views"])
    ? (PublicSchema["Tables"] &
        PublicSchema["Views"])[PublicTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  PublicTableNameOrOptions extends
    | keyof PublicSchema["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : PublicTableNameOrOptions extends keyof PublicSchema["Tables"]
    ? PublicSchema["Tables"][PublicTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  PublicTableNameOrOptions extends
    | keyof PublicSchema["Tables"]
    | { schema: keyof Database },
  TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? Database[PublicTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : PublicTableNameOrOptions extends keyof PublicSchema["Tables"]
    ? PublicSchema["Tables"][PublicTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  PublicEnumNameOrOptions extends
    | keyof PublicSchema["Enums"]
    | { schema: keyof Database },
  EnumName extends PublicEnumNameOrOptions extends { schema: keyof Database }
    ? keyof Database[PublicEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = PublicEnumNameOrOptions extends { schema: keyof Database }
  ? Database[PublicEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : PublicEnumNameOrOptions extends keyof PublicSchema["Enums"]
    ? PublicSchema["Enums"][PublicEnumNameOrOptions]
    : never

