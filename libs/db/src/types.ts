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
          assignee_id: string | null
          at: unknown | null
          author_id: string
          created_at: string
          deleted_at: string | null
          done_at: string | null
          draft: boolean
          duration: unknown | null
          id: string
          links: Json | null
          note: string | null
          on: unknown | null
          order: number
          path: unknown
          priority_id: string
          private: boolean
          recurrence_dates: string[] | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: Json | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
          actor: unknown | null
        }
        Insert: {
          assignee_id?: string | null
          at?: unknown | null
          author_id: string
          created_at?: string
          deleted_at?: string | null
          done_at?: string | null
          draft?: boolean
          duration?: unknown | null
          id?: string
          links?: Json | null
          note?: string | null
          on?: unknown | null
          order?: number
          path?: unknown
          priority_id: string
          private?: boolean
          recurrence_dates?: string[] | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: Json | null
          title?: string | null
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
          updated_by?: number
        }
        Update: {
          assignee_id?: string | null
          at?: unknown | null
          author_id?: string
          created_at?: string
          deleted_at?: string | null
          done_at?: string | null
          draft?: boolean
          duration?: unknown | null
          id?: string
          links?: Json | null
          note?: string | null
          on?: unknown | null
          order?: number
          path?: unknown
          priority_id?: string
          private?: boolean
          recurrence_dates?: string[] | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          source?: Json | null
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_exception: {
        Row: {
          activity_id: string
          at: unknown | null
          created_at: string
          deleted_at: string | null
          done_at: string | null
          duration: unknown | null
          id: string
          note: string | null
          occurrence: string
          on: unknown | null
          source: Json | null
          title: string | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          activity_id: string
          at?: unknown | null
          created_at?: string
          deleted_at?: string | null
          done_at?: string | null
          duration?: unknown | null
          id?: string
          note?: string | null
          occurrence: string
          on?: unknown | null
          source?: Json | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          at?: unknown | null
          created_at?: string
          deleted_at?: string | null
          done_at?: string | null
          duration?: unknown | null
          id?: string
          note?: string | null
          occurrence?: string
          on?: unknown | null
          source?: Json | null
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
            referencedRelation: "activity_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_exception"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_exception_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_unread"
            referencedColumns: ["activity_id"]
          },
        ]
      }
      activity_read: {
        Row: {
          activity_path: unknown
          read_at: string
          updated_at: string
          user_id: string
        }
        Insert: {
          activity_path: unknown
          read_at?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          activity_path?: unknown
          read_at?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      activity_tag: {
        Row: {
          activity_id: string
          actor_id: string
          deleted_at: string | null
          occurrence: string | null
          tag_id: number
          updated_at: string
          updated_by: number
        }
        Insert: {
          activity_id: string
          actor_id: string
          deleted_at?: string | null
          occurrence?: string | null
          tag_id: number
          updated_at?: string
          updated_by?: number
        }
        Update: {
          activity_id?: string
          actor_id?: string
          deleted_at?: string | null
          occurrence?: string | null
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
            referencedRelation: "activity_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_exception"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_unread"
            referencedColumns: ["activity_id"]
          },
        ]
      }
      agent: {
        Row: {
          created_at: string
          deleted_at: string | null
          description: string | null
          environment: Database["public"]["Enums"]["agent_environment"]
          id: string
          name: string
          updated_at: string
          user_id: string | null
          version: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          environment?: Database["public"]["Enums"]["agent_environment"]
          id: string
          name: string
          updated_at?: string
          user_id?: string | null
          version: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          environment?: Database["public"]["Enums"]["agent_environment"]
          id?: string
          name?: string
          updated_at?: string
          user_id?: string | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_id_fkey"
            columns: ["id"]
            isOneToOne: false
            referencedRelation: "agent_admin"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_admin: {
        Row: {
          auto_approve: boolean
          created_at: string
          id: string
          priority_id: string | null
          publisher_id: number | null
          updated_at: string
        }
        Insert: {
          auto_approve?: boolean
          created_at?: string
          id?: string
          priority_id?: string | null
          publisher_id?: number | null
          updated_at?: string
        }
        Update: {
          auto_approve?: boolean
          created_at?: string
          id?: string
          priority_id?: string | null
          publisher_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "agent_admin_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_admin_publisher_id_fkey"
            columns: ["publisher_id"]
            isOneToOne: false
            referencedRelation: "publisher"
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
          id: string
          name: string | null
          updated_at: string
          user_id: string | null
          organization:
            | Database["public"]["Tables"]["organization"]["Row"]
            | null
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          email: string
          id?: string
          name?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string
          id?: string
          name?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: []
      }
      cost: {
        Row: {
          amount: number | null
          created_at: string
          id: number
          name: string
          updated_at: string
        }
        Insert: {
          amount?: number | null
          created_at?: string
          id?: never
          name: string
          updated_at?: string
        }
        Update: {
          amount?: number | null
          created_at?: string
          id?: never
          name?: string
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
          id: string
          path: unknown
          root: boolean
          title: string
          updated_at: string
          updated_by: number
        }
        Insert: {
          created_at?: string
          created_by: string
          deleted_at?: string | null
          id?: string
          path: unknown
          root?: boolean
          title: string
          updated_at?: string
          updated_by?: number
        }
        Update: {
          created_at?: string
          created_by?: string
          deleted_at?: string | null
          id?: string
          path?: unknown
          root?: boolean
          title?: string
          updated_at?: string
          updated_by?: number
        }
        Relationships: []
      }
      priority_agent: {
        Row: {
          agent_environment: Database["public"]["Enums"]["agent_environment"]
          agent_id: string
          config: Json
          created_at: string
          deleted_at: string | null
          id: string
          name: string
          owner_id: string
          priority_id: string
          updated_at: string
        }
        Insert: {
          agent_environment: Database["public"]["Enums"]["agent_environment"]
          agent_id: string
          config?: Json
          created_at?: string
          deleted_at?: string | null
          id?: string
          name: string
          owner_id: string
          priority_id: string
          updated_at?: string
        }
        Update: {
          agent_environment?: Database["public"]["Enums"]["agent_environment"]
          agent_id?: string
          config?: Json
          created_at?: string
          deleted_at?: string | null
          id?: string
          name?: string
          owner_id?: string
          priority_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_agent_agent_id_agent_environment_fkey"
            columns: ["agent_id", "agent_environment"]
            isOneToOne: false
            referencedRelation: "agent"
            referencedColumns: ["id", "environment"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_contact: {
        Row: {
          contact_id: string
          created_at: string
          deleted_at: string | null
          id: number
          priority_id: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          deleted_at?: string | null
          id?: never
          priority_id: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          deleted_at?: string | null
          id?: never
          priority_id?: string
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_settings: {
        Row: {
          color: number | null
          path: unknown | null
          pomodoro: number | null
          priority_id: string
          top_order: number | null
          updated_at: string
          user_id: string
        }
        Insert: {
          color?: number | null
          path?: unknown | null
          pomodoro?: number | null
          priority_id: string
          top_order?: number | null
          updated_at?: string
          user_id: string
        }
        Update: {
          color?: number | null
          path?: unknown | null
          pomodoro?: number | null
          priority_id?: string
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_settings_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_user: {
        Row: {
          created_at: string
          deleted_at: string | null
          priority_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          priority_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
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
          updated_by: number
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
          updated_by?: number
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      token: {
        Row: {
          created_at: string
          deleted_at: string | null
          id: string
          last_used_at: string | null
          name: string | null
          publisher_id: number | null
          token: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          last_used_at?: string | null
          name?: string | null
          publisher_id?: number | null
          token: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
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
      usage: {
        Row: {
          amount: number
          cost_id: number
          created_at: string
          date: string
          id: number
          priority_agent_id: string
          updated_at: string
        }
        Insert: {
          amount: number
          cost_id: number
          created_at?: string
          date: string
          id?: never
          priority_agent_id: string
          updated_at?: string
        }
        Update: {
          amount?: number
          cost_id?: number
          created_at?: string
          date?: string
          id?: never
          priority_agent_id?: string
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
            foreignKeyName: "usage_priority_agent_id_fkey"
            columns: ["priority_agent_id"]
            isOneToOne: false
            referencedRelation: "priority_agent"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_agent_id_fkey"
            columns: ["priority_agent_id"]
            isOneToOne: false
            referencedRelation: "priority_child_agent"
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
        Relationships: []
      }
    }
    Views: {
      activity_children: {
        Row: {
          child_id: string | null
          id: string | null
        }
        Relationships: []
      }
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
            referencedRelation: "activity_children"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "activity_children"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_exception"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activity_tag_activity_id_fkey"
            columns: ["activity_id"]
            isOneToOne: false
            referencedRelation: "user_activity_unread"
            referencedColumns: ["activity_id"]
          },
        ]
      }
      actor: {
        Row: {
          avatar_url: string | null
          created_at: string | null
          deleted_at: string | null
          email: string | null
          id: string | null
          name: string | null
          type: string | null
          updated_at: string | null
        }
        Relationships: []
      }
      priority_child: {
        Row: {
          child_id: string | null
          priority_id: string | null
        }
        Relationships: []
      }
      priority_child_agent: {
        Row: {
          agent_environment:
            | Database["public"]["Enums"]["agent_environment"]
            | null
          agent_id: string | null
          author_email: string | null
          author_name: string | null
          author_url: string | null
          config: Json | null
          created_at: string | null
          deleted_at: string | null
          id: string | null
          name: string | null
          owner_id: string | null
          priority_child_id: string | null
          priority_id: string | null
          updated_at: string | null
          version: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_agent_agent_id_agent_environment_fkey"
            columns: ["agent_id", "agent_environment"]
            isOneToOne: false
            referencedRelation: "agent"
            referencedColumns: ["id", "environment"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_agent_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      user_activity: {
        Row: {
          assignee_id: string | null
          at: unknown | null
          author_id: string | null
          created_at: string | null
          deleted_at: string | null
          done_at: string | null
          draft: boolean | null
          duration: unknown | null
          id: string | null
          links: Json | null
          note: string | null
          on: unknown | null
          order: number | null
          path: unknown | null
          priority_id: string | null
          private: boolean | null
          range_at: unknown | null
          range_on: unknown | null
          recurrence_dates: string[] | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: Json | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
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
            referencedRelation: "priority_child_agent"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "priority_settings_inherited"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "activity_priority_id_fkey"
            columns: ["priority_id"]
            isOneToOne: false
            referencedRelation: "user_priority"
            referencedColumns: ["id"]
          },
        ]
      }
      user_activity_exception: {
        Row: {
          at: unknown | null
          id: string | null
          note: string | null
          occurrence: string | null
          on: unknown | null
          range_at: unknown | null
          range_on: unknown | null
          title: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_activity_tags: {
        Row: {
          id: string | null
          occurrence: string | null
          range_at: unknown | null
          range_on: unknown | null
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_activity_unread: {
        Row: {
          activity_id: string | null
          unread: boolean | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      user_priority: {
        Row: {
          color: number | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          path: unknown | null
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
    }
    Functions: {
      _ltree_compress: {
        Args: { "": unknown }
        Returns: unknown
      }
      _ltree_gist_options: {
        Args: { "": unknown }
        Returns: undefined
      }
      activity_thread: {
        Args: { p_activity_id: string }
        Returns: {
          assignee_id: string | null
          at: unknown | null
          author_id: string
          created_at: string
          deleted_at: string | null
          done_at: string | null
          draft: boolean
          duration: unknown | null
          id: string
          links: Json | null
          note: string | null
          on: unknown | null
          order: number
          path: unknown
          priority_id: string
          private: boolean
          recurrence_dates: string[] | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          source: Json | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
          updated_by: number
        }[]
      }
      actor: {
        Args: { "": Database["public"]["Tables"]["activity"]["Row"] }
        Returns: {
          avatar_url: string | null
          created_at: string | null
          deleted_at: string | null
          email: string | null
          id: string | null
          name: string | null
          type: string | null
          updated_at: string | null
        }[]
      }
      all_views_secure: {
        Args: Record<PropertyKey, never>
        Returns: boolean
      }
      binary_quantize: {
        Args: { "": string } | { "": unknown }
        Returns: unknown
      }
      can_access_priority: {
        Args: { _priority_id: string } | { _priority_path: unknown }
        Returns: boolean
      }
      count_not_null: {
        Args: { val: unknown }
        Returns: number
      }
      gen_random_uuid_v7: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      generate_path: {
        Args: { parent?: unknown }
        Returns: unknown
      }
      get_accessible_agents: {
        Args: { p_priority_id: string }
        Returns: {
          created_at: string
          deleted_at: string | null
          description: string | null
          environment: Database["public"]["Enums"]["agent_environment"]
          id: string
          name: string
          updated_at: string
          user_id: string | null
          version: string
        }[]
      }
      get_api_root: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      get_domain: {
        Args: { email: string }
        Returns: string
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
      halfvec_avg: {
        Args: { "": number[] }
        Returns: unknown
      }
      halfvec_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      halfvec_send: {
        Args: { "": unknown }
        Returns: string
      }
      halfvec_typmod_in: {
        Args: { "": unknown[] }
        Returns: number
      }
      hash_ltree: {
        Args: { "": unknown }
        Returns: number
      }
      hnsw_bit_support: {
        Args: { "": unknown }
        Returns: unknown
      }
      hnsw_halfvec_support: {
        Args: { "": unknown }
        Returns: unknown
      }
      hnsw_sparsevec_support: {
        Args: { "": unknown }
        Returns: unknown
      }
      hnswhandler: {
        Args: { "": unknown }
        Returns: unknown
      }
      insert_domain: {
        Args: { email: string }
        Returns: number
      }
      is_accessible_agent: {
        Args: {
          p_agent_environment: Database["public"]["Enums"]["agent_environment"]
          p_agent_id: string
          p_priority_id: string
        }
        Returns: boolean
      }
      is_finite: {
        Args: { test: unknown }
        Returns: boolean
      }
      is_lower: {
        Args: { "": string }
        Returns: boolean
      }
      ivfflat_bit_support: {
        Args: { "": unknown }
        Returns: unknown
      }
      ivfflat_halfvec_support: {
        Args: { "": unknown }
        Returns: unknown
      }
      ivfflathandler: {
        Args: { "": unknown }
        Returns: unknown
      }
      l2_norm: {
        Args: { "": unknown } | { "": unknown }
        Returns: number
      }
      l2_normalize: {
        Args: { "": string } | { "": unknown } | { "": unknown }
        Returns: string
      }
      lca: {
        Args: { "": unknown[] }
        Returns: unknown
      }
      lquery_in: {
        Args: { "": unknown }
        Returns: unknown
      }
      lquery_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      lquery_recv: {
        Args: { "": unknown }
        Returns: unknown
      }
      lquery_send: {
        Args: { "": unknown }
        Returns: string
      }
      ltree_compress: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_decompress: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_gist_in: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_gist_options: {
        Args: { "": unknown }
        Returns: undefined
      }
      ltree_gist_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_in: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_recv: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltree_send: {
        Args: { "": unknown }
        Returns: string
      }
      ltree2text: {
        Args: { "": unknown }
        Returns: string
      }
      ltxtq_in: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltxtq_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltxtq_recv: {
        Args: { "": unknown }
        Returns: unknown
      }
      ltxtq_send: {
        Args: { "": unknown }
        Returns: string
      }
      migrate_existing_users_to_contacts: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      nlevel: {
        Args: { "": unknown }
        Returns: number
      }
      order_first: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      organization: {
        Args: { "": Database["public"]["Tables"]["contact"]["Row"] }
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
      redeem_invitation_code: {
        Args: { invitation_code: string; user_id: string }
        Returns: Json
      }
      server_timestamp: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      set_user_status: {
        Args: { status: string; user_id: string }
        Returns: undefined
      }
      sparsevec_out: {
        Args: { "": unknown }
        Returns: unknown
      }
      sparsevec_send: {
        Args: { "": unknown }
        Returns: string
      }
      sparsevec_typmod_in: {
        Args: { "": unknown[] }
        Returns: number
      }
      text2ltree: {
        Args: { "": string }
        Returns: unknown
      }
      tstzrange_to_daterange: {
        Args: { p_range: unknown; p_timezone?: string }
        Returns: unknown
      }
      update_activity_tags: {
        Args: {
          p_activity_id: string
          p_client_id: number
          p_tag_updates: Json
          p_user_id: string
        }
        Returns: undefined
      }
      upsert_activity: {
        Args: {
          p_at?: unknown
          p_deleted_at?: string
          p_do_on?: string
          p_done_at?: string
          p_draft?: boolean
          p_duration?: unknown
          p_id: string
          p_note?: string
          p_occurrence_start?: string
          p_on?: unknown
          p_order?: number
          p_path?: unknown
          p_priority_id?: string
          p_private?: boolean
          p_recurrence_dates?: string[]
          p_recurrence_exdates?: string[]
          p_recurrence_rule?: string
          p_series?: string
          p_title?: string
          p_updated_by: number
          p_user_id: string
        }
        Returns: string
      }
      upsert_contacts: {
        Args: {
          _contacts: Database["public"]["CompositeTypes"]["contact_upsert"][]
        }
        Returns: undefined
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
      user_contact_id: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      user_has_priority_access: {
        Args:
          | { target_priority_id: string; user_id: string }
          | { target_priority_path: unknown; user_id: string }
        Returns: boolean
      }
      user_timezone: {
        Args: Record<PropertyKey, never>
        Returns: string
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
        Args: { name: string; namespace: string }
        Returns: string
      }
      uuid_generate_v4: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      uuid_generate_v5: {
        Args: { name: string; namespace: string }
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
        Args: { "": number[] }
        Returns: string
      }
      vector_dims: {
        Args: { "": string } | { "": unknown }
        Returns: number
      }
      vector_norm: {
        Args: { "": string }
        Returns: number
      }
      vector_out: {
        Args: { "": string }
        Returns: unknown
      }
      vector_send: {
        Args: { "": string }
        Returns: string
      }
      vector_typmod_in: {
        Args: { "": unknown[] }
        Returns: number
      }
      week_from_date: {
        Args: { d: string }
        Returns: unknown
      }
    }
    Enums: {
      activity_type: "task" | "event" | "note"
      agent_environment: "personal" | "private" | "review" | "public"
      subscription_plan: "free"
      subscription_status:
        | "active"
        | "canceled"
        | "past_due"
        | "trialing"
        | "incomplete"
        | "incomplete_expired"
        | "unpaid"
      tag_type: "toggle" | "count" | "compute"
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
      operation: {
        Args: Record<PropertyKey, never>
        Returns: string
      }
      search: {
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
      search_v2: {
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
      activity_type: ["task", "event", "note"],
      agent_environment: ["personal", "private", "review", "public"],
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
      tag_type: ["toggle", "count", "compute"],
    },
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS"],
    },
  },
} as const

