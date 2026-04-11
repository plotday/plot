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
      ai_key: {
        Row: {
          created_at: string
          custom_base_url: string | null
          encrypted_key: string
          fast_model: string | null
          id: number
          iv: string
          key_suffix: string
          name: string | null
          organization_id: number | null
          provider: Database["public"]["Enums"]["ai_provider"]
          thinking_model: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          custom_base_url?: string | null
          encrypted_key: string
          fast_model?: string | null
          id?: never
          iv: string
          key_suffix: string
          name?: string | null
          organization_id?: number | null
          provider: Database["public"]["Enums"]["ai_provider"]
          thinking_model?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          custom_base_url?: string | null
          encrypted_key?: string
          fast_model?: string | null
          id?: never
          iv?: string
          key_suffix?: string
          name?: string | null
          organization_id?: number | null
          provider?: Database["public"]["Enums"]["ai_provider"]
          thinking_model?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ai_key_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_key_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_preference: {
        Row: {
          builtin_ai_disabled: boolean
          builtin_ai_key_id: number | null
          created_at: string
          id: number
          organization_id: number | null
          twist_ai_disabled: boolean
          twist_ai_key_id: number | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          builtin_ai_disabled?: boolean
          builtin_ai_key_id?: number | null
          created_at?: string
          id?: never
          organization_id?: number | null
          twist_ai_disabled?: boolean
          twist_ai_key_id?: number | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          builtin_ai_disabled?: boolean
          builtin_ai_key_id?: number | null
          created_at?: string
          id?: never
          organization_id?: number | null
          twist_ai_disabled?: boolean
          twist_ai_key_id?: number | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ai_preference_builtin_ai_key_id_fkey"
            columns: ["builtin_ai_key_id"]
            referencedRelation: "ai_key"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_preference_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_preference_twist_ai_key_id_fkey"
            columns: ["twist_ai_key_id"]
            referencedRelation: "ai_key"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_preference_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      contact: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string
          email: string | null
          id: string
          name: string | null
          primary: boolean
          updated_at: string
          user_id: string | null
        }
        Insert: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          email?: string | null
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
          email?: string | null
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
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_invitation_redeemed_by_fkey"
            columns: ["redeemed_by"]
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
      device: {
        Row: {
          app_version: string | null
          created_at: string
          id: string
          platform: string
          push_token: string
          updated_at: string
          user_id: string
        }
        Insert: {
          app_version?: string | null
          created_at?: string
          id?: string
          platform: string
          push_token: string
          updated_at?: string
          user_id: string
        }
        Update: {
          app_version?: string | null
          created_at?: string
          id?: string
          platform?: string
          push_token?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      domain: {
        Row: {
          auto_join: boolean
          created_at: string
          id: number
          name: string
          organization_id: number | null
        }
        Insert: {
          auto_join?: boolean
          created_at?: string
          id?: never
          name: string
          organization_id?: number | null
        }
        Update: {
          auto_join?: boolean
          created_at?: string
          id?: never
          name?: string
          organization_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
        ]
      }
      email_claim: {
        Row: {
          attempts: number
          code: string
          created_at: string
          email: string
          expires_at: string
          id: string
          user_id: string
        }
        Insert: {
          attempts?: number
          code: string
          created_at?: string
          email: string
          expires_at: string
          id?: string
          user_id: string
        }
        Update: {
          attempts?: number
          code?: string
          created_at?: string
          email?: string
          expires_at?: string
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "email_claim_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      link: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          channel_id: string | null
          created_at: string
          created_by: string | null
          embedding: unknown
          id: string
          logo: string | null
          match: Json | null
          merged_from_thread_id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          related_source: string | null
          source: string | null
          source_created_at: string
          source_priority_root: unknown
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          actions?: Json | null
          assignee_id?: string | null
          author_id?: string | null
          channel_id?: string | null
          created_at?: string
          created_by?: string | null
          embedding?: unknown
          id?: string
          logo?: string | null
          match?: Json | null
          merged_from_thread_id?: string | null
          meta?: Json | null
          preview?: string | null
          priority_id?: string | null
          related_source?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
          source_url?: string | null
          status?: string | null
          sync_depth?: number | null
          thread_id?: string | null
          title?: string | null
          twist_id?: number | null
          type?: string | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          actions?: Json | null
          assignee_id?: string | null
          author_id?: string | null
          channel_id?: string | null
          created_at?: string
          created_by?: string | null
          embedding?: unknown
          id?: string
          logo?: string | null
          match?: Json | null
          merged_from_thread_id?: string | null
          meta?: Json | null
          preview?: string | null
          priority_id?: string | null
          related_source?: string | null
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
          source_url?: string | null
          status?: string | null
          sync_depth?: number | null
          thread_id?: string | null
          title?: string | null
          twist_id?: number | null
          type?: string | null
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "link_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "link_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      note: {
        Row: {
          access_contacts: string[] | null
          actions: Json | null
          archived_at: string | null
          author_id: string
          content: string | null
          created_at: string
          created_by: string
          draft: boolean
          embedding: unknown
          id: string
          key: string | null
          mentions: string[] | null
          merged_from_thread_id: string | null
          re_note_id: string | null
          source_created_at: string
          sync_depth: number | null
          thread_id: string
          updated_at: string
          updated_by: number
        }
        Insert: {
          access_contacts?: string[] | null
          actions?: Json | null
          archived_at?: string | null
          author_id: string
          content?: string | null
          created_at?: string
          created_by: string
          draft?: boolean
          embedding?: unknown
          id?: string
          key?: string | null
          mentions?: string[] | null
          merged_from_thread_id?: string | null
          re_note_id?: string | null
          source_created_at?: string
          sync_depth?: number | null
          thread_id: string
          updated_at?: string
          updated_by?: number
        }
        Update: {
          access_contacts?: string[] | null
          actions?: Json | null
          archived_at?: string | null
          author_id?: string
          content?: string | null
          created_at?: string
          created_by?: string
          draft?: boolean
          embedding?: unknown
          id?: string
          key?: string | null
          mentions?: string[] | null
          merged_from_thread_id?: string | null
          re_note_id?: string | null
          source_created_at?: string
          sync_depth?: number | null
          thread_id?: string
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
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
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
        ]
      }
      organization: {
        Row: {
          billing_email: string | null
          created_at: string
          id: number
          name: string
          updated_at: string
        }
        Insert: {
          billing_email?: string | null
          created_at?: string
          id?: never
          name: string
          updated_at?: string
        }
        Update: {
          billing_email?: string | null
          created_at?: string
          id?: never
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      organization_invitation: {
        Row: {
          created_at: string
          email: string
          id: number
          invited_by: string
          organization_id: number
          role: Database["public"]["Enums"]["organization_role"]
        }
        Insert: {
          created_at?: string
          email: string
          id?: never
          invited_by: string
          organization_id: number
          role?: Database["public"]["Enums"]["organization_role"]
        }
        Update: {
          created_at?: string
          email?: string
          id?: never
          invited_by?: string
          organization_id?: number
          role?: Database["public"]["Enums"]["organization_role"]
        }
        Relationships: [
          {
            foreignKeyName: "organization_invitation_invited_by_fkey"
            columns: ["invited_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_invitation_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_member: {
        Row: {
          created_at: string
          id: number
          organization_id: number
          role: Database["public"]["Enums"]["organization_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: never
          organization_id: number
          role?: Database["public"]["Enums"]["organization_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: never
          organization_id?: number
          role?: Database["public"]["Enums"]["organization_role"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_member_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_member_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_subscription: {
        Row: {
          billing_cycle_end: string
          billing_cycle_start: string
          connection_group_quantity: number
          created_at: string
          id: number
          organization_id: number
          plan: Database["public"]["Enums"]["subscription_plan"]
          status: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          updated_at: string
        }
        Insert: {
          billing_cycle_end: string
          billing_cycle_start: string
          connection_group_quantity?: number
          created_at?: string
          id?: never
          organization_id: number
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          updated_at?: string
        }
        Update: {
          billing_cycle_end?: string
          billing_cycle_start?: string
          connection_group_quantity?: number
          created_at?: string
          id?: never
          organization_id?: number
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_subscription_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
            referencedColumns: ["id"]
          },
        ]
      }
      priority: {
        Row: {
          archived_at: string | null
          color: number | null
          created_at: string
          created_by: string
          default_thread_icon: string | null
          id: string
          inherit_members: boolean
          key: string | null
          organization_id: number | null
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
          default_thread_icon?: string | null
          id?: string
          inherit_members?: boolean
          key?: string | null
          organization_id?: number | null
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
          default_thread_icon?: string | null
          id?: string
          inherit_members?: boolean
          key?: string | null
          organization_id?: number | null
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
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organization"
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
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_invited_by_fkey"
            columns: ["invited_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_setting: {
        Row: {
          key: string
          priority_id: string
          updated_at: string
          user_id: string
          value: Json
        }
        Insert: {
          key: string
          priority_id: string
          updated_at?: string
          user_id: string
          value: Json
        }
        Update: {
          key?: string
          priority_id?: string
          updated_at?: string
          user_id?: string
          value?: Json
        }
        Relationships: [
          {
            foreignKeyName: "priority_setting_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_setting_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_setting_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_setting_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_setting_user_id_fkey"
            columns: ["user_id"]
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
          priority_id: string | null
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
          priority_id?: string | null
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
          priority_id?: string | null
          suspended_at?: string | null
          twist_id?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_owner_id_fkey"
            columns: ["owner_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_twist_id_fkey"
            columns: ["twist_id"]
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_channel: {
        Row: {
          channel_id: string
          created_at: string
          enabled: boolean
          id: number
          priority_twist_id: string
          source_priority_twist_id: string
          updated_at: string
        }
        Insert: {
          channel_id: string
          created_at?: string
          enabled?: boolean
          id?: never
          priority_twist_id: string
          source_priority_twist_id: string
          updated_at?: string
        }
        Update: {
          channel_id?: string
          created_at?: string
          enabled?: boolean
          id?: never
          priority_twist_id?: string
          source_priority_twist_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_source_priority_twist_id_fkey"
            columns: ["source_priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_source_priority_twist_id_fkey"
            columns: ["source_priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_connection: {
        Row: {
          actor_id: string
          connected_at: string
          priority_twist_id: string
          provider: string
          user_id: string
        }
        Insert: {
          actor_id: string
          connected_at?: string
          priority_twist_id: string
          provider: string
          user_id: string
        }
        Update: {
          actor_id?: string
          connected_at?: string
          priority_twist_id?: string
          provider?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_twist_connection_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_connection_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_connection_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
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
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_sync_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
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
          role: string
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          personal?: boolean
          priority_id: string
          role?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          personal?: boolean
          priority_id?: string
          role?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_user_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_user_user_id_fkey"
            columns: ["user_id"]
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
      schedule: {
        Row: {
          archived_at: string | null
          at: unknown
          created_at: string
          duration: string | null
          id: string
          link_id: string | null
          occurrence: string | null
          on: unknown
          order: number | null
          outstanding_tasks: boolean
          reason: string | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          thread_id: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          archived_at?: string | null
          at?: unknown
          created_at?: string
          duration?: string | null
          id?: string
          link_id?: string | null
          occurrence?: string | null
          on?: unknown
          order?: number | null
          outstanding_tasks?: boolean
          reason?: string | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          thread_id?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          at?: unknown
          created_at?: string
          duration?: string | null
          id?: string
          link_id?: string | null
          occurrence?: string | null
          on?: unknown
          order?: number | null
          outstanding_tasks?: boolean
          reason?: string | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          thread_id?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_link_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["link_id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      schedule_contact: {
        Row: {
          archived_at: string | null
          contact_id: string
          created_at: string
          id: number
          role: string
          schedule_id: string
          status: string | null
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          contact_id: string
          created_at?: string
          id?: never
          role?: string
          schedule_id: string
          status?: string | null
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          contact_id?: string
          created_at?: string
          id?: never
          role?: string
          schedule_id?: string
          status?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "schedule_contact_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_contact_schedule_id_fkey"
            columns: ["schedule_id"]
            referencedRelation: "priority_twist_thread_schedule"
            referencedColumns: ["schedule_id"]
          },
          {
            foreignKeyName: "schedule_contact_schedule_id_fkey"
            columns: ["schedule_id"]
            referencedRelation: "schedule"
            referencedColumns: ["id"]
          },
        ]
      }
      secure_option: {
        Row: {
          created_at: string
          encrypted_value: string
          id: number
          iv: string
          key: string
          priority_twist_id: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          encrypted_value: string
          id?: never
          iv: string
          key: string
          priority_twist_id: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          encrypted_value?: string
          id?: never
          iv?: string
          key?: string
          priority_twist_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "secure_option_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "secure_option_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "secure_option_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "series_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "series_user_id_fkey"
            columns: ["user_id"]
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "session_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "session_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      source_channel: {
        Row: {
          channel_id: string
          create_threads: string
          create_threads_by_type: Json | null
          created_at: string
          enabled: boolean
          id: number
          link_types: Json | null
          priority_id: string | null
          priority_twist_id: string
          title: string
          updated_at: string
        }
        Insert: {
          channel_id: string
          create_threads?: string
          create_threads_by_type?: Json | null
          created_at?: string
          enabled?: boolean
          id?: never
          link_types?: Json | null
          priority_id?: string | null
          priority_twist_id: string
          title: string
          updated_at?: string
        }
        Update: {
          channel_id?: string
          create_threads?: string
          create_threads_by_type?: Json | null
          created_at?: string
          enabled?: boolean
          id?: never
          link_types?: Json | null
          priority_id?: string | null
          priority_twist_id?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "source_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
        ]
      }
      thread: {
        Row: {
          access: string
          access_contacts: string[] | null
          archived_at: string | null
          created_at: string
          created_by: string
          draft: boolean
          icon: string | null
          id: string
          key: string | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          preview: string | null
          priority_id: string
          sync_depth: number | null
          title: string | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          access?: string
          access_contacts?: string[] | null
          archived_at?: string | null
          created_at?: string
          created_by: string
          draft?: boolean
          icon?: string | null
          id?: string
          key?: string | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          preview?: string | null
          priority_id: string
          sync_depth?: number | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          access?: string
          access_contacts?: string[] | null
          archived_at?: string | null
          created_at?: string
          created_by?: string
          draft?: boolean
          icon?: string | null
          id?: string
          key?: string | null
          last_note_created_at?: string | null
          last_note_source_created_at?: string | null
          preview?: string | null
          priority_id?: string
          sync_depth?: number | null
          title?: string | null
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      thread_association: {
        Row: {
          archived_at: string | null
          child_thread_id: string
          created_at: string
          id: string
          order: number
          parent_thread_id: string
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          child_thread_id: string
          created_at?: string
          id?: string
          order: number
          parent_thread_id: string
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          child_thread_id?: string
          created_at?: string
          id?: string
          order?: number
          parent_thread_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_parent_thread_id_fkey"
            columns: ["parent_thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_association_parent_thread_id_fkey"
            columns: ["parent_thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_parent_thread_id_fkey"
            columns: ["parent_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_parent_thread_id_fkey"
            columns: ["parent_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      thread_read: {
        Row: {
          bumped_at: string | null
          read_at: string
          thread_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          bumped_at?: string | null
          read_at?: string
          thread_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          bumped_at?: string | null
          read_at?: string
          thread_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "thread_read_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_read_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_read_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_read_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_read_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      thread_tag: {
        Row: {
          actor_id: string
          archived_at: string | null
          id: number
          occurrence: string | null
          sync_depth: number | null
          tag_id: number
          thread_id: string
          updated_at: string
          updated_by: number
        }
        Insert: {
          actor_id: string
          archived_at?: string | null
          id?: never
          occurrence?: string | null
          sync_depth?: number | null
          tag_id: number
          thread_id: string
          updated_at?: string
          updated_by?: number
        }
        Update: {
          actor_id?: string
          archived_at?: string | null
          id?: never
          occurrence?: string | null
          sync_depth?: number | null
          tag_id?: number
          thread_id?: string
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      thread_unread: {
        Row: {
          bumped_at: string | null
          importance: number
          read_at: string | null
          thread_id: string
          updated_at: string
          urgency: string
          user_id: string
        }
        Insert: {
          bumped_at?: string | null
          importance?: number
          read_at?: string | null
          thread_id: string
          updated_at?: string
          urgency: string
          user_id: string
        }
        Update: {
          bumped_at?: string | null
          importance?: number
          read_at?: string | null
          thread_id?: string
          updated_at?: string
          urgency?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_user_id_fkey"
            columns: ["user_id"]
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
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "token_user_id_fkey"
            columns: ["user_id"]
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
          execution_limit: number | null
          id: number
          is_source: boolean
          key_option: string | null
          logo_url: string | null
          logo_url_dark: string | null
          name: string
          options: Json | null
          permissions: Json | null
          shared: boolean
          twist_admin_id: number
          updated_at: string
          version: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          execution_limit?: number | null
          id?: never
          is_source?: boolean
          key_option?: string | null
          logo_url?: string | null
          logo_url_dark?: string | null
          name: string
          options?: Json | null
          permissions?: Json | null
          shared?: boolean
          twist_admin_id: number
          updated_at?: string
          version: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          execution_limit?: number | null
          id?: never
          is_source?: boolean
          key_option?: string | null
          logo_url?: string | null
          logo_url_dark?: string | null
          name?: string
          options?: Json | null
          permissions?: Json | null
          shared?: boolean
          twist_admin_id?: number
          updated_at?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_twist_admin_id_fkey"
            columns: ["twist_admin_id"]
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
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_admin_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "twist_admin_publisher_id_fkey"
            columns: ["publisher_id"]
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_admin_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_reviewer: {
        Row: {
          created_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_reviewer_user_id_fkey"
            columns: ["user_id"]
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
            referencedRelation: "cost"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
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
          ai_enabled: boolean | null
          enter_behavior: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at: string
          user_id: string
        }
        Insert: {
          ai_enabled?: boolean | null
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at?: string
          user_id: string
        }
        Update: {
          ai_enabled?: boolean | null
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_settings_user_id_fkey"
            columns: ["user_id"]
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
          trial_ends_at: string | null
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
          trial_ends_at?: string | null
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
          trial_ends_at?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_subscription_user_id_fkey"
            columns: ["user_id"]
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
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
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
      link_x: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          channel_id: string | null
          created_at: string | null
          created_by: string | null
          embedding: unknown
          id: string | null
          logo: string | null
          match: Json | null
          merged_from_thread_id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          source: string | null
          source_created_at: string | null
          source_priority_root: unknown
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
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
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "priority_twist_note_update"
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
          is_source: boolean | null
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
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_twist_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "priority_twist_twist_id_fkey"
            columns: ["twist_id"]
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
          role: string | null
          status: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_contact_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_invited_by_fkey"
            columns: ["invited_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_contact_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_setting_inherited: {
        Row: {
          key: string | null
          priority_id: string | null
          source_path: unknown
          updated_at: string | null
          user_id: string | null
          value: Json | null
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
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_channel_link_create: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          channel_id: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          source: string | null
          source_created_at: string | null
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_channel_link_update: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          channel_id: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          source: string | null
          source_created_at: string | null
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_channel_note_create: {
        Row: {
          access_contacts: string[] | null
          actions: Json | null
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
          link_channel_id: string | null
          link_id: string | null
          link_meta: Json | null
          link_source: string | null
          link_source_url: string | null
          link_title: string | null
          link_type: string | null
          mentions: string[] | null
          priority_id: string | null
          priority_twist_id: string | null
          re_note_id: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_title: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_twist_channel_priority_twist_id_fkey"
            columns: ["priority_twist_id"]
            referencedRelation: "priority_twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_link_update: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          author_name: string | null
          author_type: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          source: string | null
          source_created_at: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_note_create: {
        Row: {
          access_contacts: string[] | null
          actions: Json | null
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
          mentions: string[] | null
          priority_id: string | null
          priority_twist_id: string | null
          re_note_id: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_meta: Json | null
          thread_title: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: []
      }
      priority_twist_note_update: {
        Row: {
          access_contacts: string[] | null
          actions: Json | null
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
          mentions: string[] | null
          priority_id: string | null
          priority_twist_id: string | null
          re_note_id: string | null
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_meta: Json | null
          thread_title: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "note"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "priority_twist_note_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_schedule_contact: {
        Row: {
          archived_at: string | null
          contact_id: string | null
          link_id: string | null
          priority_id: string | null
          priority_twist_id: string | null
          role: string | null
          schedule_contact_id: number | null
          schedule_id: string | null
          status: string | null
          thread_id: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "schedule_contact_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_contact_schedule_id_fkey"
            columns: ["schedule_id"]
            referencedRelation: "priority_twist_thread_schedule"
            referencedColumns: ["schedule_id"]
          },
          {
            foreignKeyName: "schedule_contact_schedule_id_fkey"
            columns: ["schedule_id"]
            referencedRelation: "schedule"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_link_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_channel_note_create"
            referencedColumns: ["link_id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "priority_twist_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_thread_read: {
        Row: {
          priority_id: string | null
          priority_twist_id: string | null
          read_at: string | null
          thread_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_unread_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_thread_schedule: {
        Row: {
          at: unknown
          on: unknown
          priority_id: string | null
          priority_twist_id: string | null
          schedule_id: string | null
          thread_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      priority_twist_thread_tag_change: {
        Row: {
          actor_id: string | null
          change_type: string | null
          occurrence: string | null
          priority_twist_id: string | null
          tag_id: number | null
          thread_id: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_twist_thread_update: {
        Row: {
          access: string | null
          access_contacts: string[] | null
          archived_at: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          id: string | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          priority_twist_id: string | null
          sync_depth: number | null
          tags: Json | null
          title: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
      thread_tags: {
        Row: {
          occurrence: string | null
          tags: Json | null
          thread_id: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_schedule_contact"
            referencedColumns: ["thread_id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "priority_twist_thread_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_tag_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      thread_x: {
        Row: {
          access: string | null
          access_contacts: string[] | null
          archived_at: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          icon: string | null
          id: string | null
          key: string | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          sync_depth: number | null
          title: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child_twist"
            referencedColumns: ["priority_child_id"]
          },
        ]
      }
    }
    Functions: {
      activate_invited_user: { Args: { p_user_id: string }; Returns: Json }
      archive_links: {
        Args: { p_created_by: string; p_filter?: Json }
        Returns: string[]
      }
      count_not_null: { Args: { val: unknown }; Returns: number }
      find_matching_threads_scored: {
        Args: {
          created_by_id: string
          query_embedding: string
          required_filters?: Json
          scored_fields?: Json
          similarity_threshold?: number
          thread_data?: Json
        }
        Returns: {
          id: string
          priority_id: string
          title: string
          total_score: number
        }[]
      }
      find_similar_threads: {
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
      generate_path: { Args: { parent?: unknown }; Returns: unknown }
      get_accessible_twists: {
        Args: { p_priority_id: string; p_user_id: string }
        Returns: {
          archived_at: string | null
          created_at: string
          description: string | null
          environment: Database["public"]["Enums"]["twist_environment"]
          execution_limit: number | null
          id: number
          is_source: boolean
          key_option: string | null
          logo_url: string | null
          logo_url_dark: string | null
          name: string
          options: Json | null
          permissions: Json | null
          shared: boolean
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
      move_priority: {
        Args: { p_new_parent_path: unknown; p_priority_id: string }
        Returns: undefined
      }
      notify_displaced_priority_users: {
        Args: {
          p_new_parent_path: unknown
          p_old_path: unknown
          p_priority_id: string
        }
        Returns: {
          displaced_user_id: string
        }[]
      }
      order_first: { Args: never; Returns: number }
      parent_path: { Args: { p: unknown }; Returns: unknown }
      recompute_outstanding_tasks: {
        Args: { p_thread_id: string; p_user_id: string }
        Returns: undefined
      }
      redeem_invitation_token: {
        Args: { p_token: string; p_user_id: string }
        Returns: Json
      }
      search_notes_and_links: {
        Args: {
          exclude_created_by?: string
          match_limit?: number
          query_embedding: string
          requesting_user_id: string
          scope_priority_id: string
          similarity_threshold?: number
        }
        Returns: {
          content: string
          priority_id: string
          priority_title: string
          result_id: string
          result_type: string
          similarity: number
          source_url: string
          thread_id: string
          thread_title: string
          title: string
        }[]
      }
      setup_plot_app_priority: { Args: { p_user_id: string }; Returns: Json }
      share_priority: {
        Args: {
          p_add_actor_ids: string[]
          p_priority_id: string
          p_remove_actor_ids: string[]
          p_role?: string
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
      update_invitation_sent_at: {
        Args: { p_contact_id: string }
        Returns: undefined
      }
      updated_by_uuid: { Args: { id: string }; Returns: number }
      upsert_contacts: {
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
      user_has_priority_access: {
        Args: { p_priority_id: string; p_user_id: string }
        Returns: boolean
      }
      week_from_date: { Args: { d: string }; Returns: unknown }
    }
    Enums: {
      ai_provider: "openai" | "anthropic" | "google" | "custom"
      enter_behavior: "enter_newline" | "enter_submits"
      organization_role: "admin" | "member"
      subscription_plan: "free" | "core" | "pro" | "team"
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
      [_ in never]: never
    }
  }
  user: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      actor: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string | null
          email: string | null
          id: string | null
          min_depth: number | null
          name: string | null
          self: boolean | null
          type: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      link: {
        Row: {
          actions: Json | null
          assignee_id: string | null
          author_id: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          logo: string | null
          merged_from_thread_id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          source: string | null
          source_created_at: string | null
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: []
      }
      note: {
        Row: {
          access_contacts: string[] | null
          actions: Json | null
          archived_at: string | null
          author_id: string | null
          content: string | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          id: string | null
          mentions: string[] | null
          merged_from_thread_id: string | null
          re_note_id: string | null
          source_created_at: string | null
          thread_id: string | null
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
          priority_id: string | null
          priority_path: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority: {
        Row: {
          archived_at: string | null
          attention_window: Json | null
          attention_window_set: boolean | null
          color: number | null
          created_at: string | null
          created_by: string | null
          global_path: unknown
          id: string | null
          inherit_members: boolean | null
          key: string | null
          order: number | null
          organization_id: number | null
          path: unknown
          personal: boolean | null
          pomodoro: number | null
          role: string | null
          root: boolean | null
          see_within_requests: Json | null
          see_within_requests_set: boolean | null
          see_within_updates: Json | null
          see_within_updates_set: boolean | null
          title: string | null
          top_order: number | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: []
      }
      priority_actor: {
        Row: {
          actor_id: string | null
          archived_at: string | null
          created_at: string | null
          depth: number | null
          priority_path: unknown
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority_expanded: {
        Row: {
          archived_at: string | null
          joined_at: string | null
          path: unknown
          priority_id: string | null
          role: string | null
          user_id: string | null
        }
        Relationships: []
      }
      priority_unread: {
        Row: {
          priority_id: string | null
          unread: boolean | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      schedule: {
        Row: {
          archived_at: string | null
          at: unknown
          contacts: Json | null
          created_at: string | null
          duration: string | null
          id: string | null
          link_id: string | null
          occurrence: string | null
          on: unknown
          order: number | null
          outstanding_tasks: boolean | null
          priority_path: unknown
          range_at: unknown
          range_on: unknown
          reason: string | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          schedule_user_id: string | null
          thread_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link"
            referencedColumns: ["id"]
          },
        ]
      }
      source_channel: {
        Row: {
          channel_id: string | null
          create_threads: string | null
          create_threads_by_type: Json | null
          created_at: string | null
          enabled: boolean | null
          id: number | null
          link_types: Json | null
          priority_id: string | null
          priority_twist_id: string | null
          title: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "source_channel_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_unread"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      thread: {
        Row: {
          access: string | null
          access_contacts: string[] | null
          activity_at: string | null
          agenda_at: unknown
          archived_at: string | null
          bumped_at: string | null
          created_at: string | null
          draft: boolean | null
          icon: string | null
          id: string | null
          importance: number | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          title: string | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          urgency: string | null
          user_id: string | null
        }
        Relationships: []
      }
      thread_association: {
        Row: {
          archived_at: string | null
          child_thread_id: string | null
          created_at: string | null
          id: string | null
          order: number | null
          parent_thread_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      thread_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          occurrence: string | null
          priority_id: string | null
          priority_path: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      twist: {
        Row: {
          archived_at: string | null
          config: Json | null
          created_at: string | null
          default_mention_created: boolean | null
          default_mention_mentioned: boolean | null
          id: string | null
          is_source: boolean | null
          key_option: string | null
          link_types: Json | null
          logo_url: string | null
          logo_url_dark: string | null
          name: string | null
          owner_id: string | null
          priority_id: string | null
          shared: boolean | null
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          user_connected: boolean | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      assert_priority_access: {
        Args: { priority_id: string; user_id: string }
        Returns: undefined
      }
      clear_thread_unread: {
        Args: {
          p_bumped_at?: string
          p_read_at?: string
          p_thread_id: string
          user_id: string
        }
        Returns: undefined
      }
      delete_thread_read: {
        Args: { p_thread_id: string; user_id: string }
        Returns: undefined
      }
      get_effective_role: {
        Args: { p_priority_id: string; p_user_id: string }
        Returns: string
      }
      has_priority_access: {
        Args: { priority_id: string; user_id: string }
        Returns: boolean
      }
      update_note_tags: {
        Args: {
          p_actor_id: string
          p_client_id: number
          p_note_id: string
          p_tag_updates: Json
          user_id: string
        }
        Returns: undefined
      }
      update_schedule_contact_status: {
        Args: { p_schedule_id: string; p_status: string; user_id: string }
        Returns: undefined
      }
      update_thread_tags: {
        Args: {
          p_actor_id: string
          p_client_id: number
          p_occurrence?: string
          p_tag_updates: Json
          p_thread_id: string
          user_id: string
        }
        Returns: undefined
      }
      upsert_link: {
        Args: { p_defaults?: Json; p_link: Json; user_id: string }
        Returns: Database["public"]["Tables"]["link"]["Row"]
        SetofOptions: {
          from: "*"
          to: "link"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_note: {
        Args: {
          p_access_contacts: string[]
          p_actions: Json
          p_archived_at: string
          p_author_id: string
          p_content: string
          p_created_by: string
          p_draft: boolean
          p_id: string
          p_key: string
          p_mentions: string[]
          p_merged_from_thread_id?: string
          p_re_note_id: string
          p_source_created_at: string
          p_thread_id: string
          p_updated_by: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["note"]["Row"]
        SetofOptions: {
          from: "*"
          to: "note"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_note_tag: {
        Args: {
          p_actor_id: string
          p_archived_at?: string
          p_note_id: string
          p_tag_id: number
          p_updated_by?: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["note_tag"]["Row"]
        SetofOptions: {
          from: "*"
          to: "note_tag"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_priority: {
        Args: { p_priority: Json; user_id: string }
        Returns: {
          archived_at: string | null
          attention_window: Json | null
          attention_window_set: boolean | null
          color: number | null
          created_at: string | null
          created_by: string | null
          global_path: unknown
          id: string | null
          inherit_members: boolean | null
          key: string | null
          order: number | null
          organization_id: number | null
          path: unknown
          personal: boolean | null
          pomodoro: number | null
          role: string | null
          root: boolean | null
          see_within_requests: Json | null
          see_within_requests_set: boolean | null
          see_within_updates: Json | null
          see_within_updates_set: boolean | null
          title: string | null
          top_order: number | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "priority"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_priority_attention: {
        Args: {
          p_attention_window?: Json
          p_priority_id: string
          p_see_within_requests?: Json
          p_see_within_updates?: Json
          p_set_attention_window?: boolean
          p_set_see_within_requests?: boolean
          p_set_see_within_updates?: boolean
          p_user_id: string
        }
        Returns: undefined
      }
      upsert_priority_member: {
        Args: {
          p_contact_id: string
          p_invited_at: string
          p_invited_by: string
          p_priority_id: string
          user_id: string
        }
        Returns: Database["public"]["Views"]["priority_member"]["Row"]
        SetofOptions: {
          from: "*"
          to: "priority_member"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_priority_twist: {
        Args: {
          p_archived_at: string
          p_config: Json
          p_id: string
          p_name: string
          p_owner_id: string
          p_priority_id: string
          p_twist_id: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["priority_twist"]["Row"]
        SetofOptions: {
          from: "*"
          to: "priority_twist"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_priority_user: {
        Args: {
          p_archived_at: string
          p_personal: boolean
          p_priority_id: string
          user_id: string
        }
        Returns: Database["public"]["Tables"]["priority_user"]["Row"]
        SetofOptions: {
          from: "*"
          to: "priority_user"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_schedule: {
        Args: { p_defaults?: Json; p_schedule: Json; user_id: string }
        Returns: Database["public"]["Tables"]["schedule"]["Row"]
        SetofOptions: {
          from: "*"
          to: "schedule"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_schedule_contacts: {
        Args: { p_contacts: Json; p_schedule_id: string; user_id: string }
        Returns: undefined
      }
      upsert_session: {
        Args: {
          p_archived_at: string
          p_at: unknown
          p_id: string
          p_pomodoro: number
          p_pomodoro_at: string
          p_precedence: number
          p_priority_id: string
          p_updated_by: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["session"]["Row"]
        SetofOptions: {
          from: "*"
          to: "session"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_thread: {
        Args: { p_defaults?: Json; p_thread: Json; user_id: string }
        Returns: Database["public"]["Tables"]["thread"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_thread_association: {
        Args: { p_association: Json; user_id: string }
        Returns: Database["public"]["Tables"]["thread_association"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread_association"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_thread_read: {
        Args: {
          p_bumped_at?: string
          p_read_at: string
          p_thread_id: string
          user_id: string
        }
        Returns: Database["public"]["Tables"]["thread_read"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread_read"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_thread_tag: {
        Args: {
          p_actor_id: string
          p_archived_at?: string
          p_occurrence?: string
          p_tag_id: number
          p_thread_id: string
          p_updated_by?: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["thread_tag"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread_tag"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_thread_unread: {
        Args: {
          p_bumped_at?: string
          p_importance?: number
          p_note_created_at?: string
          p_read_at?: string
          p_thread_id: string
          p_urgency: string
          user_id: string
        }
        Returns: Database["public"]["Tables"]["thread_unread"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread_unread"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_user_settings: {
        Args: {
          p_ai_enabled?: boolean
          p_enter_behavior: Database["public"]["Enums"]["enter_behavior"]
          user_id: string
        }
        Returns: Database["public"]["Tables"]["user_settings"]["Row"]
        SetofOptions: {
          from: "*"
          to: "user_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      user_contact_id: { Args: { p_user_id: string }; Returns: string }
      user_contact_ids: { Args: { p_user_id: string }; Returns: string[] }
    }
    Enums: {
      [_ in never]: never
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
  public: {
    Enums: {
      ai_provider: ["openai", "anthropic", "google", "custom"],
      enter_behavior: ["enter_newline", "enter_submits"],
      organization_role: ["admin", "member"],
      subscription_plan: ["free", "core", "pro", "team"],
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
  user: {
    Enums: {},
  },
} as const
