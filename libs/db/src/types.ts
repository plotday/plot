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
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
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
      activity: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown
          author_id: string
          created_at: string
          created_by: string
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean
          duration: string | null
          embedding: unknown
          id: string
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          meta: Json | null
          on: unknown
          order: number
          pick_priority: Json | null
          preview: string | null
          priority_id: string
          private: boolean
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string
          source_priority_root: unknown
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
          actor: {
            archived_at: string | null
            avatar_url: string | null
            created_at: string | null
            email: string | null
            id: string | null
            name: string | null
            type: string | null
            updated_at: string | null
          } | null
          assignee: {
            archived_at: string | null
            avatar_url: string | null
            created_at: string | null
            email: string | null
            id: string | null
            name: string | null
            type: string | null
            updated_at: string | null
          } | null
        }
        Insert: {
          archived_at?: string | null
          assignee_id?: string | null
          at?: unknown
          author_id: string
          created_at?: string
          created_by?: string
          created_by_twist_id?: number | null
          done_at?: string | null
          draft?: boolean
          duration?: string | null
          embedding?: unknown
          id?: string
          kind?: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          meta?: Json | null
          on?: unknown
          order?: number
          pick_priority?: Json | null
          preview?: string | null
          priority_id: string
          private?: boolean
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
          sync_depth?: number | null
          title?: string | null
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
          updated_by?: number
        }
        Update: {
          archived_at?: string | null
          assignee_id?: string | null
          at?: unknown
          author_id?: string
          created_at?: string
          created_by?: string
          created_by_twist_id?: number | null
          done_at?: string | null
          draft?: boolean
          duration?: string | null
          embedding?: unknown
          id?: string
          kind?: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          meta?: Json | null
          on?: unknown
          order?: number
          pick_priority?: Json | null
          preview?: string | null
          priority_id?: string
          private?: boolean
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      activity_exception: {
        Row: {
          activity_id: string
          archived_at: string | null
          at: unknown
          created_at: string
          done_at: string | null
          duration: string | null
          id: string
          meta: Json | null
          occurrence: string
          on: unknown
          preview: string | null
          title: string | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          activity_id: string
          archived_at?: string | null
          at?: unknown
          created_at?: string
          done_at?: string | null
          duration?: string | null
          id?: string
          meta?: Json | null
          occurrence: string
          on?: unknown
          preview?: string | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          archived_at?: string | null
          at?: unknown
          created_at?: string
          done_at?: string | null
          duration?: string | null
          id?: string
          meta?: Json | null
          occurrence?: string
          on?: unknown
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
          organization: {
            created_at: string
            id: number
            name: string
          } | null
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
        Relationships: []
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
          source_created_at: string
          sync_depth: number | null
          updated_at: string
          updated_by: number
          actor: {
            archived_at: string | null
            avatar_url: string | null
            created_at: string | null
            email: string | null
            id: string | null
            name: string | null
            type: string | null
            updated_at: string | null
          } | null
        }
        Insert: {
          activity_id: string
          archived_at?: string | null
          author_id: string
          content?: string | null
          created_at?: string
          created_by?: string
          draft?: boolean
          id?: string
          key?: string | null
          links?: Json | null
          mentions?: string[] | null
          private?: boolean
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
            referencedRelation: "user_note_tags"
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
        Relationships: []
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_settings: {
        Row: {
          color: number | null
          order: number | null
          path: unknown
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
          path?: unknown
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
          path?: unknown
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
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
          twist_id?: number
          updated_at?: string
        }
        Relationships: [
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
            referencedRelation: "user_twist"
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
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
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_publisher_id_fkey"
            columns: ["publisher_id"]
            isOneToOne: false
            referencedRelation: "publisher"
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
            referencedRelation: "user_twist"
            referencedColumns: ["id"]
          },
        ]
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
        Relationships: []
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
        Relationships: []
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
        Relationships: []
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
          at: unknown
          author_id: string | null
          created_at: string | null
          created_by: string | null
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean | null
          duration: string | null
          embedding: unknown
          id: string | null
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown
          order: number | null
          pick_priority: Json | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          private: boolean | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string | null
          source_priority_root: unknown
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          updated_at: string | null
          updated_by: number | null
          actor: {
            archived_at: string | null
            avatar_url: string | null
            created_at: string | null
            email: string | null
            id: string | null
            name: string | null
            type: string | null
            updated_at: string | null
          } | null
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
            referencedRelation: "user_note_tags"
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
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          version: string | null
        }
        Relationships: [
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_settings_inherited: {
        Row: {
          color: number | null
          path: unknown
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      priority_twist_activity_create: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown
          author_id: string | null
          author_name: string | null
          author_type: string | null
          created_at: string | null
          created_by: string | null
          done_at: string | null
          draft: boolean | null
          duration: string | null
          id: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
          at: unknown
          author_id: string | null
          author_name: string | null
          author_type: string | null
          created_at: string | null
          created_by: string | null
          done_at: string | null
          draft: boolean | null
          duration: string | null
          id: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
        ]
      }
      user_activity: {
        Row: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown
          author_id: string | null
          created_at: string | null
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean | null
          duration: string | null
          id: string | null
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          mentions: string[] | null
          meta: Json | null
          on: unknown
          order: number | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          private: boolean | null
          range_at: unknown
          range_on: unknown
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
          actor: {
            archived_at: string | null
            avatar_url: string | null
            created_at: string | null
            email: string | null
            id: string | null
            name: string | null
            type: string | null
            updated_at: string | null
          } | null
        }
        Relationships: []
      }
      user_activity_exception: {
        Row: {
          activity_id: string | null
          archived_at: string | null
          at: unknown
          id: string | null
          occurrence: string | null
          on: unknown
          preview: string | null
          priority_path: unknown
          range_at: unknown
          range_on: unknown
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
      user_activity_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          occurrence: string | null
          priority_path: unknown
          range_at: unknown
          range_on: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_actor: {
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
      user_note: {
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
          source_created_at: string | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: []
      }
      user_note_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          priority_path: unknown
          range_at: unknown
          range_on: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_priority: {
        Row: {
          archived_at: string | null
          color: number | null
          created_at: string | null
          created_by: string | null
          global_path: unknown
          id: string | null
          key: string | null
          order: number | null
          path: unknown
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
        Relationships: []
      }
      user_priority_actor: {
        Row: {
          actor_id: string | null
          archived_at: string | null
          created_at: string | null
          priority_path: unknown
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_priority_expanded: {
        Row: {
          archived_at: string | null
          joined_at: string | null
          priority_id: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_priority_unread: {
        Row: {
          priority_id: string | null
          unread: boolean | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_twist: {
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
            referencedColumns: ["child_id"]
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority_unread"
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
    }
    Functions: {
      activate_invited_user: { Args: { p_user_id: string }; Returns: Json }
      actor:
        | {
            Args: { "": Database["public"]["Tables"]["activity"]["Row"] }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }
            SetofOptions: {
              from: "activity"
              to: "actor"
              isOneToOne: true
              isSetofReturn: true
            }
          }
        | {
            Args: { "": Database["public"]["Views"]["activity_x"]["Row"] }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }
            SetofOptions: {
              from: "activity_x"
              to: "actor"
              isOneToOne: true
              isSetofReturn: true
            }
          }
        | {
            Args: { "": Database["public"]["Tables"]["note"]["Row"] }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }
            SetofOptions: {
              from: "note"
              to: "actor"
              isOneToOne: true
              isSetofReturn: true
            }
          }
        | {
            Args: { "": Database["public"]["Views"]["user_activity"]["Row"] }
            Returns: {
              archived_at: string | null
              avatar_url: string | null
              created_at: string | null
              email: string | null
              id: string | null
              name: string | null
              type: string | null
              updated_at: string | null
            }
            SetofOptions: {
              from: "user_activity"
              to: "actor"
              isOneToOne: true
              isSetofReturn: true
            }
          }
      all_views_secure: { Args: never; Returns: boolean }
      assignee: {
        Args: { "": Database["public"]["Tables"]["activity"]["Row"] }
        Returns: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string | null
          email: string | null
          id: string | null
          name: string | null
          type: string | null
          updated_at: string | null
        }
        SetofOptions: {
          from: "activity"
          to: "actor"
          isOneToOne: true
          isSetofReturn: true
        }
      }
      call_twist_sync_api: {
        Args: { priority_twist_ids: string[] }
        Returns: undefined
      }
      call_user_sync_api: { Args: { user_ids: string[] }; Returns: undefined }
      can_access_priority:
        | { Args: { _priority_id: string }; Returns: boolean }
        | { Args: { _priority_path: unknown }; Returns: boolean }
      count_not_null: { Args: { val: unknown }; Returns: number }
      find_matching_activities_scored: {
        Args: {
          activity_data?: Json
          created_by_id: string
          query_embedding: string
          required_filters?: Json
          scored_fields?: Json
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
          created_by_id: string
          match_limit?: number
          query_embedding: string
          similarity_threshold?: number
        }
        Returns: {
          id: string
          priority_id: string
          similarity: number
          title: string
        }[]
      }
      gen_random_uuid_v7: { Args: never; Returns: string }
      generate_path: { Args: { parent?: unknown }; Returns: unknown }
      get_accessible_twists: {
        Args: { p_priority_id: string; p_user_id: string }
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
        SetofOptions: {
          from: "*"
          to: "twist"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_activity_mentions: {
        Args: { p_activity_id: string }
        Returns: string[]
      }
      get_domain: { Args: { email: string }; Returns: string }
      get_invitation_token: {
        Args: { p_contact_id: string; p_new_token: string }
        Returns: Json
      }
      get_pending_user_sync: {
        Args: { p_user_id: string }
        Returns: {
          entity: string
          last_update_at: string
        }[]
      }
      get_primary_contact_id: { Args: { p_user_id: string }; Returns: string }
      get_priority_twist_owner_contact: {
        Args: { p_priority_twist_id: string }
        Returns: string
      }
      get_stale_twist_syncs: {
        Args: { p_limit?: number; p_stale_threshold: string }
        Returns: {
          priority_twist_id: string
        }[]
      }
      get_stale_user_syncs: {
        Args: { p_limit?: number; p_stale_threshold: string }
        Returns: {
          user_id: string
        }[]
      }
      get_tag_type: {
        Args: { tag_id: number }
        Returns: Database["public"]["Enums"]["tag_type"]
      }
      get_users_with_priority_access: {
        Args: { target_priority_id: string }
        Returns: {
          user_id: string
        }[]
      }
      insert_domain: { Args: { email: string }; Returns: number }
      is_accessible_twist: {
        Args: { p_priority_id: string; p_twist_id: number; p_user_id: string }
        Returns: boolean
      }
      is_finite: { Args: { test: unknown }; Returns: boolean }
      is_lower: { Args: { "": string }; Returns: boolean }
      is_rsvp_tag: { Args: { tag_id: number }; Returns: boolean }
      move_priority: {
        Args: { p_new_parent_path: unknown; p_priority_id: string }
        Returns: undefined
      }
      order_first: { Args: never; Returns: number }
      organization: {
        Args: { "": Database["public"]["Tables"]["contact"]["Row"] }
        Returns: {
          created_at: string
          id: number
          name: string
        }
        SetofOptions: {
          from: "contact"
          to: "organization"
          isOneToOne: true
          isSetofReturn: true
        }
      }
      parent_path: { Args: { p: unknown }; Returns: unknown }
      redeem_invitation_code: {
        Args: { invitation_code: string; user_id: string }
        Returns: Json
      }
      redeem_invitation_token: {
        Args: { p_token: string; p_user_id: string }
        Returns: Json
      }
      set_user_status: {
        Args: { status: string; user_id: string }
        Returns: undefined
      }
      setup_help_feedback_priority: {
        Args: { p_user_id?: string; p_user_name?: string }
        Returns: Json
      }
      share_priority: {
        Args: {
          p_add_actor_ids: string[]
          p_priority_id: string
          p_remove_actor_ids: string[]
          p_user_id: string
        }
        Returns: Json
      }
      sync_user_on_connect: { Args: { p_user_id: string }; Returns: undefined }
      text2ltree: { Args: { "": string }; Returns: unknown }
      tstzrange_to_daterange: {
        Args: { p_range: unknown; p_timezone?: string }
        Returns: unknown
      }
      update_activity_tags: {
        Args: {
          p_activity_id: string
          p_actor_id: string
          p_client_id: number
          p_occurrence?: string
          p_tag_updates: Json
        }
        Returns: undefined
      }
      update_invitation_sent_at: {
        Args: { p_contact_id: string }
        Returns: undefined
      }
      update_note_tags: {
        Args: {
          p_actor_id: string
          p_client_id: number
          p_note_id: string
          p_tag_updates: Json
        }
        Returns: undefined
      }
      updated_by_uuid: { Args: { id: string }; Returns: number }
      upsert_activity: {
        Args: { p_activity: Json; p_defaults?: Json }
        Returns: {
          archived_at: string | null
          assignee_id: string | null
          at: unknown
          author_id: string
          created_at: string
          created_by: string
          created_by_twist_id: number | null
          done_at: string | null
          draft: boolean
          duration: string | null
          embedding: unknown
          id: string
          kind: Database["public"]["Enums"]["activity_kind"] | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          meta: Json | null
          on: unknown
          order: number
          pick_priority: Json | null
          preview: string | null
          priority_id: string
          private: boolean
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: string | null
          source_created_at: string
          source_priority_root: unknown
          sync_depth: number | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
        }
        SetofOptions: {
          from: "*"
          to: "activity"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_contacts:
        | {
            Args: {
              _contacts: Database["public"]["CompositeTypes"]["contact_upsert"][]
            }
            Returns: undefined
          }
        | {
            Args: { contacts: Json }
            Returns: {
              email: string
              id: string
              name: string
              user_id: string
            }[]
          }
      upsert_user_contact: {
        Args: {
          avatar_url: string
          user_email: string
          user_id: string
          user_name: string
        }
        Returns: string
      }
      user_contact_id: { Args: never; Returns: string }
      user_has_priority_access:
        | {
            Args: { target_priority_id: string; user_id: string }
            Returns: boolean
          }
        | {
            Args: { target_priority_path: unknown; user_id: string }
            Returns: boolean
          }
      user_mentioned_in_activity: {
        Args: { activity_id: string; user_id: string }
        Returns: boolean
      }
      user_timezone: { Args: never; Returns: string }
      week_from_date: { Args: { d: string }; Returns: unknown }
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
          type: Database["storage"]["Enums"]["buckettype"]
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
          type?: Database["storage"]["Enums"]["buckettype"]
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
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Relationships: []
      }
      buckets_analytics: {
        Row: {
          created_at: string
          format: string
          id: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          format?: string
          id: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          format?: string
          id?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      iceberg_namespaces: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_namespaces_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
        ]
      }
      iceberg_tables: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          location: string
          name: string
          namespace_id: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id?: string
          location: string
          name: string
          namespace_id: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          location?: string
          name?: string
          namespace_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_tables_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "iceberg_tables_namespace_id_fkey"
            columns: ["namespace_id"]
            isOneToOne: false
            referencedRelation: "iceberg_namespaces"
            referencedColumns: ["id"]
          },
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
        Args: { bucketid: string; metadata: Json; name: string; owner: string }
        Returns: undefined
      }
      delete_leaf_prefixes: {
        Args: { bucket_ids: string[]; names: string[] }
        Returns: undefined
      }
      delete_prefix: {
        Args: { _bucket_id: string; _name: string }
        Returns: boolean
      }
      extension: { Args: { name: string }; Returns: string }
      filename: { Args: { name: string }; Returns: string }
      foldername: { Args: { name: string }; Returns: string[] }
      get_level: { Args: { name: string }; Returns: number }
      get_prefix: { Args: { name: string }; Returns: string }
      get_prefixes: { Args: { name: string }; Returns: string[] }
      get_size_by_bucket: {
        Args: never
        Returns: {
          bucket_id: string
          size: number
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
          prefix_param: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_token?: string
          prefix_param: string
          start_after?: string
        }
        Returns: {
          id: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      lock_top_prefixes: {
        Args: { bucket_ids: string[]; names: string[] }
        Returns: undefined
      }
      operation: { Args: never; Returns: string }
      search:
        | {
            Args: {
              bucketname: string
              levels?: number
              limits?: number
              offsets?: number
              prefix: string
            }
            Returns: {
              created_at: string
              id: string
              last_accessed_at: string
              metadata: Json
              name: string
              updated_at: string
            }[]
          }
        | {
            Args: {
              bucketname: string
              levels?: number
              limits?: number
              offsets?: number
              prefix: string
              search?: string
              sortcolumn?: string
              sortorder?: string
            }
            Returns: {
              created_at: string
              id: string
              last_accessed_at: string
              metadata: Json
              name: string
              updated_at: string
            }[]
          }
      search_legacy_v1: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v1_optimised: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v2:
        | {
            Args: {
              bucket_name: string
              levels?: number
              limits?: number
              prefix: string
              start_after?: string
            }
            Returns: {
              created_at: string
              id: string
              key: string
              metadata: Json
              name: string
              updated_at: string
            }[]
          }
        | {
            Args: {
              bucket_name: string
              levels?: number
              limits?: number
              prefix: string
              sort_column?: string
              sort_column_after?: string
              sort_order?: string
              start_after?: string
            }
            Returns: {
              created_at: string
              id: string
              key: string
              last_accessed_at: string
              metadata: Json
              name: string
              updated_at: string
            }[]
          }
    }
    Enums: {
      buckettype: "STANDARD" | "ANALYTICS"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
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
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      activity_kind: [
        "document",
        "messages",
        "meeting",
        "videoconference",
        "phone",
        "focus",
        "meal",
        "exercise",
        "family",
        "travel",
        "social",
        "entertainment",
      ],
      activity_type: ["action", "event", "note"],
      enter_behavior: ["enter_newline", "enter_submits"],
      subscription_plan: ["free"],
      subscription_status: [
        "active",
        "canceled",
        "past_due",
        "trialing",
        "incomplete",
        "incomplete_expired",
        "unpaid",
      ],
      sync_operation: ["create", "update"],
      tag_type: ["toggle", "count", "compute"],
      twist_environment: ["personal", "private", "review", "public"],
    },
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS"],
    },
  },
} as const

