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
          provider: Database["public"]["Enums"]["ai_provider"]
          team_id: number | null
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
          provider: Database["public"]["Enums"]["ai_provider"]
          team_id?: number | null
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
          provider?: Database["public"]["Enums"]["ai_provider"]
          team_id?: number | null
          thinking_model?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ai_key_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
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
          team_id: number | null
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
          team_id?: number | null
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
          team_id?: number | null
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
            foreignKeyName: "ai_preference_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
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
      channel: {
        Row: {
          channel_id: string
          created_at: string
          default_priority_id: string | null
          default_priority_reason: string | null
          enabled: boolean
          id: number
          link_types: Json | null
          seq: unknown
          title: string
          twist_instance_id: string
          updated_at: string
        }
        Insert: {
          channel_id: string
          created_at?: string
          default_priority_id?: string | null
          default_priority_reason?: string | null
          enabled?: boolean
          id?: never
          link_types?: Json | null
          seq?: unknown
          title: string
          twist_instance_id: string
          updated_at?: string
        }
        Update: {
          channel_id?: string
          created_at?: string
          default_priority_id?: string | null
          default_priority_reason?: string | null
          enabled?: boolean
          id?: never
          link_types?: Json | null
          seq?: unknown
          title?: string
          twist_instance_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "channel_default_priority_id_fkey"
            columns: ["default_priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "channel_default_priority_id_fkey"
            columns: ["default_priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "channel_default_priority_id_fkey"
            columns: ["default_priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
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
          inviteable: boolean
          name: string | null
          primary: boolean
          seq: unknown
          updated_at: string
          user_id: string | null
        }
        Insert: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          id?: string
          inviteable?: boolean
          name?: string | null
          primary?: boolean
          seq?: unknown
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          id?: string
          inviteable?: boolean
          name?: string | null
          primary?: boolean
          seq?: unknown
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
          twist_instance_id: string
        }
        Insert: {
          account_id: string
          contact_id: string
          data_fetched_at?: string
          last_reported_at?: string | null
          provider: string
          twist_instance_id: string
        }
        Update: {
          account_id?: string
          contact_id?: string
          data_fetched_at?: string
          last_reported_at?: string | null
          provider?: string
          twist_instance_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_external_account_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_external_account_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_external_account_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contact_external_account_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
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
          team_id: number | null
        }
        Insert: {
          auto_join?: boolean
          created_at?: string
          id?: never
          name: string
          team_id?: number | null
        }
        Update: {
          auto_join?: boolean
          created_at?: string
          id?: never
          name?: string
          team_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
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
      extracted_url: {
        Row: {
          attempts: number
          author: string | null
          byte_size: number | null
          created_at: string
          description: string | null
          error_code: string | null
          error_message: string | null
          extracted_at: string | null
          extractor_version: number
          id: number
          last_attempt_at: string | null
          r2_key: string | null
          status: string
          title: string | null
          updated_at: string
          url: string
          url_hash: string
        }
        Insert: {
          attempts?: number
          author?: string | null
          byte_size?: number | null
          created_at?: string
          description?: string | null
          error_code?: string | null
          error_message?: string | null
          extracted_at?: string | null
          extractor_version?: number
          id?: never
          last_attempt_at?: string | null
          r2_key?: string | null
          status?: string
          title?: string | null
          updated_at?: string
          url: string
          url_hash: string
        }
        Update: {
          attempts?: number
          author?: string | null
          byte_size?: number | null
          created_at?: string
          description?: string | null
          error_code?: string | null
          error_message?: string | null
          extracted_at?: string | null
          extractor_version?: number
          id?: never
          last_attempt_at?: string | null
          r2_key?: string | null
          status?: string
          title?: string | null
          updated_at?: string
          url?: string
          url_hash?: string
        }
        Relationships: []
      }
      group: {
        Row: {
          archived_at: string | null
          auto_maintained: boolean
          auto_publisher_id: number | null
          auto_team_admin_team_id: number | null
          created_at: string
          created_by: string
          id: string
          join_policy: Database["public"]["Enums"]["group_join_policy"]
          key: string | null
          name: string
          seq: unknown
          team_id: number | null
          type: Database["public"]["Enums"]["group_type"]
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          auto_maintained?: boolean
          auto_publisher_id?: number | null
          auto_team_admin_team_id?: number | null
          created_at?: string
          created_by: string
          id?: string
          join_policy?: Database["public"]["Enums"]["group_join_policy"]
          key?: string | null
          name: string
          seq?: unknown
          team_id?: number | null
          type?: Database["public"]["Enums"]["group_type"]
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          auto_maintained?: boolean
          auto_publisher_id?: number | null
          auto_team_admin_team_id?: number | null
          created_at?: string
          created_by?: string
          id?: string
          join_policy?: Database["public"]["Enums"]["group_join_policy"]
          key?: string | null
          name?: string
          seq?: unknown
          team_id?: number | null
          type?: Database["public"]["Enums"]["group_type"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_auto_publisher_id_fkey"
            columns: ["auto_publisher_id"]
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_auto_team_admin_team_id_fkey"
            columns: ["auto_team_admin_team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_created_by_fkey"
            columns: ["created_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
        ]
      }
      group_admin: {
        Row: {
          created_at: string
          group_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          group_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          group_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_admin_group_id_fkey"
            columns: ["group_id"]
            referencedRelation: "group"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_admin_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      group_member: {
        Row: {
          contact_id: string
          created_at: string
          group_id: string
          updated_at: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          group_id: string
          updated_at?: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          group_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "group_member_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "group_member_group_id_fkey"
            columns: ["group_id"]
            referencedRelation: "group"
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
          id: string
          logo: string | null
          merged_from_thread_id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          related_source: string | null
          seq: unknown
          source: string | null
          source_created_at: string
          source_priority_root: unknown
          source_url: string | null
          sources: string[]
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
          id?: string
          logo?: string | null
          merged_from_thread_id?: string | null
          meta?: Json | null
          preview?: string | null
          priority_id?: string | null
          related_source?: string | null
          seq?: unknown
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
          source_url?: string | null
          sources?: string[]
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
          id?: string
          logo?: string | null
          merged_from_thread_id?: string | null
          meta?: Json | null
          preview?: string | null
          priority_id?: string | null
          related_source?: string | null
          seq?: unknown
          source?: string | null
          source_created_at?: string
          source_priority_root?: unknown
          source_url?: string | null
          sources?: string[]
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
          canonical_source: string | null
          content: string | null
          created_at: string
          created_by: string
          draft: boolean
          embedding: unknown
          external_content_hash: string | null
          id: string
          key: string | null
          link_id: string | null
          mentions: string[] | null
          merged_from_thread_id: string | null
          re_note_id: string | null
          seq: unknown
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
          canonical_source?: string | null
          content?: string | null
          created_at?: string
          created_by: string
          draft?: boolean
          embedding?: unknown
          external_content_hash?: string | null
          id?: string
          key?: string | null
          link_id?: string | null
          mentions?: string[] | null
          merged_from_thread_id?: string | null
          re_note_id?: string | null
          seq?: unknown
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
          canonical_source?: string | null
          content?: string | null
          created_at?: string
          created_by?: string
          draft?: boolean
          embedding?: unknown
          external_content_hash?: string | null
          id?: string
          key?: string | null
          link_id?: string | null
          mentions?: string[] | null
          merged_from_thread_id?: string | null
          re_note_id?: string | null
          seq?: unknown
          source_created_at?: string
          sync_depth?: number | null
          thread_id?: string
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "link_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_link_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["link_id"]
          },
          {
            foreignKeyName: "note_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_link_update"
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_update"
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
          seq: unknown
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
          seq?: unknown
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
          seq?: unknown
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "twist_instance_note_update"
            referencedColumns: ["id"]
          },
        ]
      }
      priority: {
        Row: {
          archived_at: string | null
          color: number | null
          config: Json | null
          created_at: string
          created_by: string
          default_contacts: string[]
          default_groups: string[]
          default_invite_emails: string[]
          default_thread_icon: string | null
          id: string
          inherit_members: boolean
          key: string | null
          path: unknown
          seq: unknown
          sync_depth: number | null
          team_id: number | null
          title: string
          updated_at: string
          updated_by: number
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          color?: number | null
          config?: Json | null
          created_at?: string
          created_by: string
          default_contacts?: string[]
          default_groups?: string[]
          default_invite_emails?: string[]
          default_thread_icon?: string | null
          id?: string
          inherit_members?: boolean
          key?: string | null
          path: unknown
          seq?: unknown
          sync_depth?: number | null
          team_id?: number | null
          title: string
          updated_at?: string
          updated_by?: number
          user_id: string
        }
        Update: {
          archived_at?: string | null
          color?: number | null
          config?: Json | null
          created_at?: string
          created_by?: string
          default_contacts?: string[]
          default_groups?: string[]
          default_invite_emails?: string[]
          default_thread_icon?: string | null
          id?: string
          inherit_members?: boolean
          key?: string | null
          path?: unknown
          seq?: unknown
          sync_depth?: number | null
          team_id?: number | null
          title?: string
          updated_at?: string
          updated_by?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_created_by_fkey"
            columns: ["created_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      priority_block: {
        Row: {
          archived_at: string | null
          created_at: string
          created_by: string
          duration: string | null
          effective_at: string
          id: string
          order_value: number
          priority_id: string
          seq: unknown
          updated_at: string
          updated_by: number
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          created_by: string
          duration?: string | null
          effective_at: string
          id?: string
          order_value: number
          priority_id: string
          seq?: unknown
          updated_at?: string
          updated_by?: number
          user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          created_by?: string
          duration?: string | null
          effective_at?: string
          id?: string
          order_value?: number
          priority_id?: string
          seq?: unknown
          updated_at?: string
          updated_by?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "priority_block_created_by_fkey"
            columns: ["created_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_block_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_block_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "priority_block_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_block_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
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
            foreignKeyName: "priority_setting_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      publisher: {
        Row: {
          created_at: string
          created_by: string
          email: string | null
          id: number
          name: string
          updated_at: string
          url: string | null
        }
        Insert: {
          created_at?: string
          created_by: string
          email?: string | null
          id?: never
          name: string
          updated_at?: string
          url?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string
          email?: string | null
          id?: never
          name?: string
          updated_at?: string
          url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "publisher_created_by_fkey"
            columns: ["created_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
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
          reason: string | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          seq: unknown
          thread_id: string | null
          updated_at: string
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
          reason?: string | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          seq?: unknown
          thread_id?: string | null
          updated_at?: string
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
          reason?: string | null
          recurrence_exdates?: string[] | null
          recurrence_rule?: string | null
          seq?: unknown
          thread_id?: string | null
          updated_at?: string
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
            referencedRelation: "twist_instance_channel_link_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["link_id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_link_update"
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
          seq: unknown
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
          seq?: unknown
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
          seq?: unknown
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
          twist_instance_id: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          encrypted_value: string
          id?: never
          iv: string
          key: string
          twist_instance_id: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          encrypted_value?: string
          id?: never
          iv?: string
          key?: string
          twist_instance_id?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "secure_option_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "secure_option_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "secure_option_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
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
          explicit: boolean
          id: string
          occurrence_at: string | null
          pomodoro: number | null
          pomodoro_at: string | null
          precedence: number
          priority_id: string | null
          schedule_id: string | null
          seq: unknown
          source: string
          updated_at: string
          updated_by: number
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          at: unknown
          created_at?: string
          explicit?: boolean
          id?: string
          occurrence_at?: string | null
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          schedule_id?: string | null
          seq?: unknown
          source?: string
          updated_at?: string
          updated_by?: number
          user_id: string
        }
        Update: {
          archived_at?: string | null
          at?: unknown
          created_at?: string
          explicit?: boolean
          id?: string
          occurrence_at?: string | null
          pomodoro?: number | null
          pomodoro_at?: string | null
          precedence?: number
          priority_id?: string | null
          schedule_id?: string | null
          seq?: unknown
          source?: string
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
            foreignKeyName: "session_schedule_id_fkey"
            columns: ["schedule_id"]
            referencedRelation: "schedule"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      team: {
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
      team_invitation: {
        Row: {
          created_at: string
          email: string
          id: number
          invited_by: string
          role: Database["public"]["Enums"]["team_role"]
          team_id: number
        }
        Insert: {
          created_at?: string
          email: string
          id?: never
          invited_by: string
          role?: Database["public"]["Enums"]["team_role"]
          team_id: number
        }
        Update: {
          created_at?: string
          email?: string
          id?: never
          invited_by?: string
          role?: Database["public"]["Enums"]["team_role"]
          team_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "team_invitation_invited_by_fkey"
            columns: ["invited_by"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "team_invitation_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
        ]
      }
      team_subscription: {
        Row: {
          billing_cycle_end: string
          billing_cycle_start: string
          connection_group_quantity: number
          created_at: string
          id: number
          plan: Database["public"]["Enums"]["subscription_plan"]
          status: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          team_id: number
          updated_at: string
        }
        Insert: {
          billing_cycle_end: string
          billing_cycle_start: string
          connection_group_quantity?: number
          created_at?: string
          id?: never
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          team_id: number
          updated_at?: string
        }
        Update: {
          billing_cycle_end?: string
          billing_cycle_start?: string
          connection_group_quantity?: number
          created_at?: string
          id?: never
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          team_id?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "team_subscription_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
        ]
      }
      team_user: {
        Row: {
          archived_at: string | null
          created_at: string
          id: number
          role: Database["public"]["Enums"]["team_role"]
          seq: unknown
          team_id: number
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          id?: never
          role?: Database["public"]["Enums"]["team_role"]
          seq?: unknown
          team_id: number
          user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          id?: never
          role?: Database["public"]["Enums"]["team_role"]
          seq?: unknown
          team_id?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "team_user_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "team_user_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      thread: {
        Row: {
          archived_at: string | null
          contacts: string[]
          created_at: string
          created_by: string
          draft: boolean
          embedding: unknown
          groups: string[]
          icon: string | null
          id: string
          key: string | null
          last_note_created_at: string | null
          last_note_seq: unknown
          last_note_source_created_at: string | null
          merged_into_thread_id: string | null
          pending_contacts: string[]
          preview: string | null
          seq: unknown
          sync_depth: number | null
          title: string | null
          topic: string | null
          twist_id: number | null
          updated_at: string
          updated_by: number
        }
        Insert: {
          archived_at?: string | null
          contacts?: string[]
          created_at?: string
          created_by: string
          draft?: boolean
          embedding?: unknown
          groups?: string[]
          icon?: string | null
          id?: string
          key?: string | null
          last_note_created_at?: string | null
          last_note_seq?: unknown
          last_note_source_created_at?: string | null
          merged_into_thread_id?: string | null
          pending_contacts?: string[]
          preview?: string | null
          seq?: unknown
          sync_depth?: number | null
          title?: string | null
          topic?: string | null
          twist_id?: number | null
          updated_at?: string
          updated_by?: number
        }
        Update: {
          archived_at?: string | null
          contacts?: string[]
          created_at?: string
          created_by?: string
          draft?: boolean
          embedding?: unknown
          groups?: string[]
          icon?: string | null
          id?: string
          key?: string | null
          last_note_created_at?: string | null
          last_note_seq?: unknown
          last_note_source_created_at?: string | null
          merged_into_thread_id?: string | null
          pending_contacts?: string[]
          preview?: string | null
          seq?: unknown
          sync_depth?: number | null
          title?: string | null
          topic?: string | null
          twist_id?: number | null
          updated_at?: string
          updated_by?: number
        }
        Relationships: [
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
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
          seq: unknown
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          child_thread_id: string
          created_at?: string
          id?: string
          order: number
          parent_thread_id: string
          seq?: unknown
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          child_thread_id?: string
          created_at?: string
          id?: string
          order?: number
          parent_thread_id?: string
          seq?: unknown
          updated_at?: string
        }
        Relationships: [
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
      thread_priority: {
        Row: {
          applied_default_channel_id: number | null
          archived_at: string | null
          auto_archived_by_thread_id: string | null
          classify_at: string | null
          created_at: string
          priority_id: string | null
          revoked_at: string | null
          seq: unknown
          thread_id: string
          updated_at: string
          user_id: string
          user_moved: boolean
        }
        Insert: {
          applied_default_channel_id?: number | null
          archived_at?: string | null
          auto_archived_by_thread_id?: string | null
          classify_at?: string | null
          created_at?: string
          priority_id?: string | null
          revoked_at?: string | null
          seq?: unknown
          thread_id: string
          updated_at?: string
          user_id: string
          user_moved?: boolean
        }
        Update: {
          applied_default_channel_id?: number | null
          archived_at?: string | null
          auto_archived_by_thread_id?: string | null
          classify_at?: string | null
          created_at?: string
          priority_id?: string | null
          revoked_at?: string | null
          seq?: unknown
          thread_id?: string
          updated_at?: string
          user_id?: string
          user_moved?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_auto_archived_by_thread_id_fkey"
            columns: ["auto_archived_by_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_auto_archived_by_thread_id_fkey"
            columns: ["auto_archived_by_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_priority_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      thread_read: {
        Row: {
          bumped_at: string | null
          read_at: string
          seq: unknown
          thread_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          bumped_at?: string | null
          read_at?: string
          seq?: unknown
          thread_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          bumped_at?: string | null
          read_at?: string
          seq?: unknown
          thread_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
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
      thread_state: {
        Row: {
          active: boolean
          at: unknown
          bumped_at: string | null
          importance: number
          on: unknown
          order: number | null
          read_at: string | null
          seq: unknown
          task: boolean
          thread_id: string
          to_read: boolean
          updated_at: string
          urgent: boolean
          user_id: string
        }
        Insert: {
          active?: boolean
          at?: unknown
          bumped_at?: string | null
          importance?: number
          on?: unknown
          order?: number | null
          read_at?: string | null
          seq?: unknown
          task?: boolean
          thread_id: string
          to_read?: boolean
          updated_at?: string
          urgent?: boolean
          user_id: string
        }
        Update: {
          active?: boolean
          at?: unknown
          bumped_at?: string | null
          importance?: number
          on?: unknown
          order?: number | null
          read_at?: string | null
          seq?: unknown
          task?: boolean
          thread_id?: string
          to_read?: boolean
          updated_at?: string
          urgent?: boolean
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_user_id_fkey"
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
          seq: unknown
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
          seq?: unknown
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
          seq?: unknown
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
          auto_approve: boolean
          created_at: string
          description: string | null
          environment: Database["public"]["Enums"]["twist_environment"]
          execution_limit: number | null
          id: number
          is_source: boolean
          key_option: string | null
          logo_url: string | null
          logo_url_dark: string | null
          multiple_instances: boolean
          name: string
          options_schema: Json | null
          permissions: Json | null
          publisher_id: number | null
          shared: boolean
          twist_package_id: string
          updated_at: string
          user_id: string | null
          version: string
        }
        Insert: {
          archived_at?: string | null
          auto_approve?: boolean
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          execution_limit?: number | null
          id?: never
          is_source?: boolean
          key_option?: string | null
          logo_url?: string | null
          logo_url_dark?: string | null
          multiple_instances?: boolean
          name: string
          options_schema?: Json | null
          permissions?: Json | null
          publisher_id?: number | null
          shared?: boolean
          twist_package_id: string
          updated_at?: string
          user_id?: string | null
          version: string
        }
        Update: {
          archived_at?: string | null
          auto_approve?: boolean
          created_at?: string
          description?: string | null
          environment?: Database["public"]["Enums"]["twist_environment"]
          execution_limit?: number | null
          id?: never
          is_source?: boolean
          key_option?: string | null
          logo_url?: string | null
          logo_url_dark?: string | null
          multiple_instances?: boolean
          name?: string
          options_schema?: Json | null
          permissions?: Json | null
          publisher_id?: number | null
          shared?: boolean
          twist_package_id?: string
          updated_at?: string
          user_id?: string | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_publisher_id_fkey"
            columns: ["publisher_id"]
            referencedRelation: "publisher"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance: {
        Row: {
          account_label: string | null
          archived_at: string | null
          created_at: string
          draft: boolean
          id: string
          name: string
          options: Json
          owner_id: string
          seq: unknown
          suspended_at: string | null
          suspended_version: string | null
          team_id: number | null
          twist_id: number
          updated_at: string
        }
        Insert: {
          account_label?: string | null
          archived_at?: string | null
          created_at?: string
          draft?: boolean
          id?: string
          name: string
          options?: Json
          owner_id: string
          seq?: unknown
          suspended_at?: string | null
          suspended_version?: string | null
          team_id?: number | null
          twist_id: number
          updated_at?: string
        }
        Update: {
          account_label?: string | null
          archived_at?: string | null
          created_at?: string
          draft?: boolean
          id?: string
          name?: string
          options?: Json
          owner_id?: string
          seq?: unknown
          suspended_at?: string | null
          suspended_version?: string | null
          team_id?: number | null
          twist_id?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_owner_id_fkey"
            columns: ["owner_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_twist_id_fkey"
            columns: ["twist_id"]
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_channel: {
        Row: {
          channel_id: string
          created_at: string
          enabled: boolean
          id: number
          source_twist_instance_id: string
          twist_instance_id: string
          updated_at: string
        }
        Insert: {
          channel_id: string
          created_at?: string
          enabled?: boolean
          id?: never
          source_twist_instance_id: string
          twist_instance_id: string
          updated_at?: string
        }
        Update: {
          channel_id?: string
          created_at?: string
          enabled?: boolean
          id?: never
          source_twist_instance_id?: string
          twist_instance_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_channel_source_twist_instance_id_fkey"
            columns: ["source_twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_source_twist_instance_id_fkey"
            columns: ["source_twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_source_twist_instance_id_fkey"
            columns: ["source_twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
        ]
      }
      twist_instance_connection: {
        Row: {
          actor_id: string
          connected_at: string
          initial_sync_completed_at: string | null
          initial_sync_started_at: string | null
          needs_reauth_at: string | null
          provider: string
          recovery_pending: boolean
          seq: unknown
          twist_instance_id: string
          user_id: string
        }
        Insert: {
          actor_id: string
          connected_at?: string
          initial_sync_completed_at?: string | null
          initial_sync_started_at?: string | null
          needs_reauth_at?: string | null
          provider: string
          recovery_pending?: boolean
          seq?: unknown
          twist_instance_id: string
          user_id: string
        }
        Update: {
          actor_id?: string
          connected_at?: string
          initial_sync_completed_at?: string | null
          initial_sync_started_at?: string | null
          needs_reauth_at?: string | null
          provider?: string
          recovery_pending?: boolean
          seq?: unknown
          twist_instance_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_connection_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_connection_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_connection_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
          {
            foreignKeyName: "twist_instance_connection_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_sync: {
        Row: {
          entity: string
          last_sync_at: string
          last_sync_seq: unknown
          last_update_at: string
          last_update_seq: unknown
          operation: Database["public"]["Enums"]["sync_operation"]
          twist_instance_id: string
        }
        Insert: {
          entity: string
          last_sync_at?: string
          last_sync_seq?: unknown
          last_update_at: string
          last_update_seq?: unknown
          operation: Database["public"]["Enums"]["sync_operation"]
          twist_instance_id: string
        }
        Update: {
          entity?: string
          last_sync_at?: string
          last_sync_seq?: unknown
          last_update_at?: string
          last_update_seq?: unknown
          operation?: Database["public"]["Enums"]["sync_operation"]
          twist_instance_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_sync_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_sync_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_sync_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
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
          twist_instance_id: string
          updated_at: string
        }
        Insert: {
          amount: number
          cost_id: number
          created_at?: string
          hour: string
          id?: never
          twist_instance_id: string
          updated_at?: string
        }
        Update: {
          amount?: number
          cost_id?: number
          created_at?: string
          hour?: string
          id?: never
          twist_instance_id?: string
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
            foreignKeyName: "usage_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "usage_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
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
      user_contact: {
        Row: {
          archived_at: string | null
          contact_id: string
          created_at: string
          linked: boolean
          primary: boolean
          seq: unknown
          source: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          contact_id: string
          created_at?: string
          linked?: boolean
          primary?: boolean
          seq?: unknown
          source?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          contact_id?: string
          created_at?: string
          linked?: boolean
          primary?: boolean
          seq?: unknown
          source?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_contact_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contact"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_contact_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      user_settings: {
        Row: {
          ai_enabled: boolean | null
          email_frequency: Database["public"]["Enums"]["email_frequency"] | null
          email_token: string | null
          enter_behavior: Database["public"]["Enums"]["enter_behavior"] | null
          event_sessions_finalized_through: string | null
          onboarding_completed: boolean | null
          seq: unknown
          tracking_paused_at: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          ai_enabled?: boolean | null
          email_frequency?:
            | Database["public"]["Enums"]["email_frequency"]
            | null
          email_token?: string | null
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          event_sessions_finalized_through?: string | null
          onboarding_completed?: boolean | null
          seq?: unknown
          tracking_paused_at?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          ai_enabled?: boolean | null
          email_frequency?:
            | Database["public"]["Enums"]["email_frequency"]
            | null
          email_token?: string | null
          enter_behavior?: Database["public"]["Enums"]["enter_behavior"] | null
          event_sessions_finalized_through?: string | null
          onboarding_completed?: boolean | null
          seq?: unknown
          tracking_paused_at?: string | null
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
          apple_original_transaction_id: string | null
          apple_product_id: string | null
          billing_cycle_end: string
          billing_cycle_start: string
          created_at: string
          id: number
          origin: string
          plan: Database["public"]["Enums"]["subscription_plan"]
          status: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          trial_ends_at: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          apple_original_transaction_id?: string | null
          apple_product_id?: string | null
          billing_cycle_end: string
          billing_cycle_start: string
          created_at?: string
          id?: never
          origin?: string
          plan?: Database["public"]["Enums"]["subscription_plan"]
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          trial_ends_at?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          apple_original_transaction_id?: string | null
          apple_product_id?: string | null
          billing_cycle_end?: string
          billing_cycle_start?: string
          created_at?: string
          id?: never
          origin?: string
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
          last_sync_seq: unknown
          last_update_at: string
          last_update_seq: unknown
          user_id: string
        }
        Insert: {
          entity: string
          last_sync_at?: string
          last_sync_seq?: unknown
          last_update_at: string
          last_update_seq?: unknown
          user_id: string
        }
        Update: {
          entity?: string
          last_sync_at?: string
          last_sync_seq?: unknown
          last_update_at?: string
          last_update_seq?: unknown
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
          inviteable: boolean | null
          name: string | null
          seq: unknown
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
          id: string | null
          logo: string | null
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
          seq: unknown
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_tag_note_id_fkey"
            columns: ["note_id"]
            referencedRelation: "twist_instance_note_update"
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
      thread_tags: {
        Row: {
          occurrence: string | null
          seq: unknown
          tags: Json | null
          thread_id: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
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
          archived_at: string | null
          contacts: string[] | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          embedding: unknown
          groups: string[] | null
          icon: string | null
          id: string | null
          key: string | null
          last_note_created_at: string | null
          last_note_seq: unknown
          last_note_source_created_at: string | null
          merged_into_thread_id: string | null
          pending_contacts: string[] | null
          preview: string | null
          seq: unknown
          sync_depth: number | null
          title: string | null
          topic: string | null
          twist_id: number | null
          updated_at: string | null
          updated_by: number | null
        }
        Insert: {
          archived_at?: string | null
          contacts?: string[] | null
          created_at?: string | null
          created_by?: string | null
          draft?: boolean | null
          embedding?: unknown
          groups?: string[] | null
          icon?: string | null
          id?: string | null
          key?: string | null
          last_note_created_at?: string | null
          last_note_seq?: unknown
          last_note_source_created_at?: string | null
          merged_into_thread_id?: string | null
          pending_contacts?: string[] | null
          preview?: string | null
          seq?: unknown
          sync_depth?: number | null
          title?: string | null
          topic?: string | null
          twist_id?: number | null
          updated_at?: string | null
          updated_by?: number | null
        }
        Update: {
          archived_at?: string | null
          contacts?: string[] | null
          created_at?: string | null
          created_by?: string | null
          draft?: boolean | null
          embedding?: unknown
          groups?: string[] | null
          icon?: string | null
          id?: string | null
          key?: string | null
          last_note_created_at?: string | null
          last_note_seq?: unknown
          last_note_source_created_at?: string | null
          merged_into_thread_id?: string | null
          pending_contacts?: string[] | null
          preview?: string | null
          seq?: unknown
          sync_depth?: number | null
          title?: string | null
          topic?: string | null
          twist_id?: number | null
          updated_at?: string | null
          updated_by?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_channel_link_create: {
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
          seq: unknown
          source: string | null
          source_created_at: string | null
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          twist_instance_id: string | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
        ]
      }
      twist_instance_channel_link_update: {
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
          seq: unknown
          source: string | null
          source_created_at: string | null
          source_url: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          twist_instance_id: string | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
        ]
      }
      twist_instance_channel_note_create: {
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
          re_note_id: string | null
          seq: unknown
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_title: string | null
          twist_instance_id: string | null
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_update"
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_details"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_channel_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["twist_instance_id"]
          },
        ]
      }
      twist_instance_details: {
        Row: {
          account_label: string | null
          archived_at: string | null
          author_email: string | null
          author_name: string | null
          author_url: string | null
          created_at: string | null
          draft: boolean | null
          id: string | null
          is_source: boolean | null
          name: string | null
          options: Json | null
          owner_id: string | null
          seq: unknown
          suspended_at: string | null
          suspended_version: string | null
          team_id: number | null
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          version: string | null
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_owner_id_fkey"
            columns: ["owner_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_team_id_fkey"
            columns: ["team_id"]
            referencedRelation: "team"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_twist_id_fkey"
            columns: ["twist_id"]
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_link_update: {
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
          source: string | null
          source_created_at: string | null
          status: string | null
          sync_depth: number | null
          thread_id: string | null
          title: string | null
          twist_id: number | null
          twist_instance_id: string | null
          type: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: [
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      twist_instance_note_create: {
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
          re_note_id: string | null
          seq: unknown
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_meta: Json | null
          thread_title: string | null
          twist_instance_id: string | null
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_update"
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      twist_instance_note_update: {
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
          re_note_id: string | null
          seq: unknown
          source_created_at: string | null
          sync_depth: number | null
          tags: Json | null
          thread_created_by: string | null
          thread_id: string | null
          thread_meta: Json | null
          thread_title: string | null
          twist_instance_id: string | null
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
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "twist_instance_note_update"
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      twist_instance_schedule_contact: {
        Row: {
          archived_at: string | null
          contact_id: string | null
          link_id: string | null
          priority_id: string | null
          role: string | null
          schedule_contact_id: number | null
          schedule_id: string | null
          seq: unknown
          status: string | null
          thread_id: string | null
          twist_instance_id: string | null
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
            referencedRelation: "twist_instance_channel_link_create"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_link_update"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_channel_note_create"
            referencedColumns: ["link_id"]
          },
          {
            foreignKeyName: "schedule_link_id_fkey"
            columns: ["link_id"]
            referencedRelation: "twist_instance_link_update"
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
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
        ]
      }
      twist_instance_thread_read: {
        Row: {
          priority_id: string | null
          read_at: string | null
          seq: unknown
          thread_id: string | null
          twist_instance_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_thread_schedule: {
        Row: {
          active: boolean | null
          at: unknown
          on: unknown
          priority_id: string | null
          read_at: string | null
          seq: unknown
          task: boolean | null
          thread_id: string | null
          to_read: boolean | null
          twist_instance_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["child_id"]
          },
          {
            foreignKeyName: "thread_priority_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_child"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_x"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_state_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "user"
            referencedColumns: ["id"]
          },
        ]
      }
      twist_instance_thread_tag_change: {
        Row: {
          actor_id: string | null
          change_type: string | null
          occurrence: string | null
          seq: unknown
          tag_id: number | null
          thread_id: string | null
          twist_instance_id: string | null
          updated_at: string | null
        }
        Relationships: [
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
      twist_instance_thread_update: {
        Row: {
          archived_at: string | null
          contacts: string[] | null
          created_at: string | null
          created_by: string | null
          draft: boolean | null
          id: string | null
          preview: string | null
          priority_id: string | null
          priority_title: string | null
          seq: unknown
          sync_depth: number | null
          tags: Json | null
          title: string | null
          twist_instance_id: string | null
          updated_at: string | null
          updated_by: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      activate_invited_user: { Args: { p_user_id: string }; Returns: Json }
      add_group_members: {
        Args: { p_contact_ids: string[]; p_group_id: string; p_user_id: string }
        Returns: undefined
      }
      apply_channel_default: { Args: { p_channel_id: number }; Returns: number }
      archive_links: {
        Args: { p_created_by: string; p_filter?: Json }
        Returns: string[]
      }
      channel_default_marker: {
        Args: { p_priority_id: string; p_thread_id: string; p_user_id: string }
        Returns: number
      }
      classify_thread_for_user: {
        Args: {
          p_contacts?: string[]
          p_embedding?: unknown
          p_groups?: string[]
          p_thread_id?: string
          p_topic?: string
          p_user_id: string
        }
        Returns: string
      }
      classify_thread_for_user_explain: {
        Args: {
          p_contacts?: string[]
          p_embedding?: unknown
          p_groups?: string[]
          p_thread_id?: string
          p_topic?: string
          p_user_id: string
        }
        Returns: {
          priority_id: string
          scores: Json
          stage: string
        }[]
      }
      classify_visibility_window: { Args: never; Returns: string }
      count_not_null: { Args: { val: unknown }; Returns: number }
      create_group: {
        Args: {
          p_join_policy?: Database["public"]["Enums"]["group_join_policy"]
          p_member_contact_ids?: string[]
          p_name: string
          p_team_id?: number
          p_type?: Database["public"]["Enums"]["group_type"]
          p_user_id: string
        }
        Returns: string
      }
      ensure_twist_dev_priority: {
        Args: { p_user_id: string }
        Returns: string
      }
      expand_contacts: { Args: { p_contacts: string[] }; Returns: string[] }
      generate_path: { Args: { parent?: unknown }; Returns: unknown }
      get_accessible_twists: {
        Args: { p_user_id: string }
        Returns: {
          archived_at: string | null
          auto_approve: boolean
          created_at: string
          description: string | null
          environment: Database["public"]["Enums"]["twist_environment"]
          execution_limit: number | null
          id: number
          is_source: boolean
          key_option: string | null
          logo_url: string | null
          logo_url_dark: string | null
          multiple_instances: boolean
          name: string
          options_schema: Json | null
          permissions: Json | null
          publisher_id: number | null
          shared: boolean
          twist_package_id: string
          updated_at: string
          user_id: string | null
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
          last_update_seq: unknown
        }[]
      }
      get_primary_contact_id: { Args: { p_user_id: string }; Returns: string }
      get_stale_twist_syncs: {
        Args: { p_limit?: number; p_stale_threshold: string }
        Returns: {
          twist_instance_id: string
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
      get_twist_instance_owner_contact: {
        Args: { p_twist_instance_id: string }
        Returns: string
      }
      get_users_with_priority_access: {
        Args: { target_priority_id: string }
        Returns: {
          user_id: string
        }[]
      }
      insert_domain: { Args: { email: string }; Returns: number }
      is_accessible_twist: {
        Args: { p_twist_id: number; p_user_id: string }
        Returns: boolean
      }
      is_finite: { Args: { test: unknown }; Returns: boolean }
      is_lower: { Args: { "": string }; Returns: boolean }
      mark_channel_default_candidates: {
        Args: { p_channel_id: number }
        Returns: {
          thread_id: string
          user_id: string
        }[]
      }
      mark_reclassify_candidates: {
        Args: {
          p_anchor_thread_id: string
          p_max_candidates?: number
          p_user_id: string
        }
        Returns: {
          thread_id: string
          user_id: string
        }[]
      }
      match_priority_for_user: {
        Args: {
          p_required_filters?: Json
          p_scored_fields?: Json
          p_similarity_threshold?: number
          p_thread_data?: Json
          p_user_id: string
          query_embedding?: string
        }
        Returns: string
      }
      move_priority: {
        Args: { p_new_parent_path: unknown; p_priority_id: string }
        Returns: undefined
      }
      normalize_title: { Args: { t: string }; Returns: string }
      order_first: { Args: never; Returns: number }
      parent_path: { Args: { p: unknown }; Returns: unknown }
      reclassify_user_threads: {
        Args: {
          p_anchor_thread_id: string
          p_max_candidates?: number
          p_user_id: string
        }
        Returns: number
      }
      redeem_invitation_token: {
        Args: { p_token: string; p_user_id: string }
        Returns: Json
      }
      remove_group_members: {
        Args: { p_contact_ids: string[]; p_group_id: string; p_user_id: string }
        Returns: undefined
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
      share_thread: {
        Args: {
          p_add_contact_ids?: string[]
          p_remove_contact_ids?: string[]
          p_thread_id: string
          p_user_id: string
        }
        Returns: Json
      }
      share_thread_with_groups: {
        Args: {
          p_add_group_ids?: string[]
          p_remove_group_ids?: string[]
          p_thread_id: string
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
      email_frequency: "daily" | "weekly" | "never"
      enter_behavior: "enter_newline" | "enter_submits"
      group_join_policy: "member" | "open" | "admin"
      group_type: "public" | "team" | "private" | "announce"
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
      team_role: "admin" | "member"
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
          external_accounts: Json | null
          id: string | null
          inviteable: boolean | null
          linked_user_id: string | null
          name: string | null
          primary: boolean | null
          self: boolean | null
          seq: unknown
          type: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      channel: {
        Row: {
          channel_id: string | null
          created_at: string | null
          default_priority_id: string | null
          default_priority_reason: string | null
          enabled: boolean | null
          id: number | null
          link_types: Json | null
          seq: unknown
          title: string | null
          twist_instance_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: []
      }
      group: {
        Row: {
          archived_at: string | null
          auto_maintained: boolean | null
          can_post: boolean | null
          created_at: string | null
          id: string | null
          is_admin: boolean | null
          is_member: boolean | null
          join_policy: Database["public"]["Enums"]["group_join_policy"] | null
          member_contact_ids: string[] | null
          name: string | null
          seq: unknown
          team_id: number | null
          type: Database["public"]["Enums"]["group_type"] | null
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
          channel_id: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          logo: string | null
          merged_from_thread_id: string | null
          meta: Json | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          seq: unknown
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
        Relationships: [
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_tags"
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
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "link_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
        ]
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
          seq: unknown
          source_created_at: string | null
          thread_id: string | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_tags"
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
            referencedRelation: "note_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "note_tags"
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
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      note_redacted: {
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
          seq: unknown
          source_created_at: string | null
          thread_id: string | null
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_merged_from_thread_id_fkey"
            columns: ["merged_from_thread_id"]
            referencedRelation: "thread_tags"
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
            referencedRelation: "note_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_re_note_id_fkey"
            columns: ["re_note_id"]
            referencedRelation: "note_tags"
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
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      note_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          priority_id: string | null
          priority_path: unknown
          seq: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      priority: {
        Row: {
          archived_at: string | null
          color: number | null
          config: Json | null
          created_at: string | null
          created_by: string | null
          default_contacts: string[] | null
          default_groups: string[] | null
          default_invite_emails: string[] | null
          early_notifications_enabled: boolean | null
          early_notifications_enabled_set: boolean | null
          global_path: unknown
          id: string | null
          inherit_members: boolean | null
          key: string | null
          notify_window: Json | null
          notify_window_set: boolean | null
          order: number | null
          path: unknown
          pomodoro: number | null
          respond_schedule_enabled: boolean | null
          respond_schedule_enabled_set: boolean | null
          respond_window: Json | null
          respond_window_set: boolean | null
          respond_within: Json | null
          respond_within_set: boolean | null
          role: string | null
          root: boolean | null
          see_within: Json | null
          see_within_set: boolean | null
          seq: unknown
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
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      priority_block: {
        Row: {
          archived_at: string | null
          created_at: string | null
          created_by: string | null
          duration: string | null
          effective_at: string | null
          id: string | null
          order_value: number | null
          priority_id: string | null
          seq: unknown
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        Insert: {
          archived_at?: string | null
          created_at?: string | null
          created_by?: string | null
          duration?: string | null
          effective_at?: string | null
          id?: string | null
          order_value?: number | null
          priority_id?: string | null
          seq?: unknown
          updated_at?: string | null
          updated_by?: number | null
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          created_at?: string | null
          created_by?: string | null
          duration?: string | null
          effective_at?: string | null
          id?: string | null
          order_value?: number | null
          priority_id?: string | null
          seq?: unknown
          updated_at?: string | null
          updated_by?: number | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_block_created_by_fkey"
            columns: ["created_by"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "priority_block_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "priority_block_priority_id_fkey"
            columns: ["priority_id"]
            referencedRelation: "priority_expanded"
            referencedColumns: ["priority_id"]
          },
          {
            foreignKeyName: "priority_block_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
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
        Insert: {
          archived_at?: string | null
          joined_at?: string | null
          path?: unknown
          priority_id?: string | null
          role?: never
          user_id?: string | null
        }
        Update: {
          archived_at?: string | null
          joined_at?: string | null
          path?: unknown
          priority_id?: string | null
          role?: never
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
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
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
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
          priority_path: unknown
          range_at: unknown
          range_on: unknown
          reason: string | null
          recurrence_exdates: string[] | null
          recurrence_rule: string | null
          seq: unknown
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
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_thread_id_fkey"
            columns: ["thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      team_user: {
        Row: {
          archived_at: string | null
          id: number | null
          role: Database["public"]["Enums"]["team_role"] | null
          seq: unknown
          team_id: number | null
          team_name: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "team_user_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      thread: {
        Row: {
          active: boolean | null
          activity_at: string | null
          agenda_at: unknown
          archived_at: string | null
          auto_archived_by_thread_id: string | null
          bumped_at: string | null
          contacts: string[] | null
          created_at: string | null
          draft: boolean | null
          groups: string[] | null
          has_embedding: boolean | null
          icon: string | null
          id: string | null
          importance: number | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          merged_into_thread_id: string | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          revoked: boolean | null
          seq: unknown
          state_at: unknown
          state_on: unknown
          state_order: number | null
          task: boolean | null
          title: string | null
          to_read: boolean | null
          topic: string | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          urgent: boolean | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_merged_into_thread_id_fkey"
            columns: ["merged_into_thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_auto_archived_by_thread_id_fkey"
            columns: ["auto_archived_by_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_auto_archived_by_thread_id_fkey"
            columns: ["auto_archived_by_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_auto_archived_by_thread_id_fkey"
            columns: ["auto_archived_by_thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      thread_association: {
        Row: {
          archived_at: string | null
          child_thread_id: string | null
          created_at: string | null
          id: string | null
          order: number | null
          parent_thread_id: string | null
          seq: unknown
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "thread"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_child_thread_id_fkey"
            columns: ["child_thread_id"]
            referencedRelation: "thread_tags"
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
            referencedRelation: "thread_redacted"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_association_parent_thread_id_fkey"
            columns: ["parent_thread_id"]
            referencedRelation: "thread_tags"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      thread_redacted: {
        Row: {
          active: boolean | null
          activity_at: string | null
          agenda_at: unknown
          archived_at: string | null
          auto_archived_by_thread_id: string | null
          bumped_at: string | null
          contacts: string[] | null
          created_at: string | null
          draft: boolean | null
          groups: string[] | null
          has_embedding: boolean | null
          icon: string | null
          id: string | null
          importance: number | null
          last_note_created_at: string | null
          last_note_source_created_at: string | null
          merged_into_thread_id: string | null
          preview: string | null
          priority_id: string | null
          priority_path: unknown
          revoked: boolean | null
          seq: unknown
          state_at: unknown
          state_on: unknown
          state_order: number | null
          task: boolean | null
          title: string | null
          to_read: boolean | null
          topic: string | null
          unread: boolean | null
          updated_at: string | null
          updated_by: number | null
          urgent: boolean | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      thread_tags: {
        Row: {
          archived_at: string | null
          id: string | null
          occurrence: string | null
          priority_id: string | null
          priority_path: unknown
          seq: unknown
          tags: Json | null
          updated_at: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "thread_priority_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      twist: {
        Row: {
          account_label: string | null
          archived_at: string | null
          created_at: string | null
          default_mention_created: boolean | null
          default_mention_mentioned: boolean | null
          id: string | null
          is_builtin: boolean | null
          is_source: boolean | null
          key_option: string | null
          link_types: Json | null
          logo_url: string | null
          logo_url_dark: string | null
          multiple_instances: boolean | null
          name: string | null
          options: Json | null
          owner_id: string | null
          seq: unknown
          shared: boolean | null
          team_id: number | null
          twist_environment:
            | Database["public"]["Enums"]["twist_environment"]
            | null
          twist_id: number | null
          updated_at: string | null
          user_connected: boolean | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_owner_id_fkey"
            columns: ["owner_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "twist_instance_owner_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
      twist_connection: {
        Row: {
          actor_id: string | null
          connected_at: string | null
          initial_sync_completed_at: string | null
          initial_sync_started_at: string | null
          initial_syncing: boolean | null
          needs_reauth: boolean | null
          needs_reauth_at: string | null
          provider: string | null
          seq: unknown
          twist_instance_id: string | null
          updated_at: string | null
          user_id: string | null
        }
        Insert: {
          actor_id?: string | null
          connected_at?: string | null
          initial_sync_completed_at?: string | null
          initial_sync_started_at?: string | null
          initial_syncing?: never
          needs_reauth?: never
          needs_reauth_at?: string | null
          provider?: string | null
          seq?: unknown
          twist_instance_id?: string | null
          updated_at?: never
          user_id?: string | null
        }
        Update: {
          actor_id?: string | null
          connected_at?: string | null
          initial_sync_completed_at?: string | null
          initial_sync_started_at?: string | null
          initial_syncing?: never
          needs_reauth?: never
          needs_reauth_at?: string | null
          provider?: string | null
          seq?: unknown
          twist_instance_id?: string | null
          updated_at?: never
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "twist_instance_connection_twist_instance_id_fkey"
            columns: ["twist_instance_id"]
            referencedRelation: "twist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "twist_instance_connection_user_id_fkey"
            columns: ["user_id"]
            referencedRelation: "group"
            referencedColumns: ["user_id"]
          },
        ]
      }
    }
    Functions: {
      apply_auto_archive: {
        Args: { p_seed_thread_id: string; p_user_id: string }
        Returns: number
      }
      apply_auto_archive_for_new_thread: {
        Args: { p_thread_id: string; p_user_id: string }
        Returns: string
      }
      assert_priority_access: {
        Args: { priority_id: string; user_id: string }
        Returns: undefined
      }
      canonical_contact_id: { Args: { p_contact_id: string }; Returns: string }
      clear_auto_archive: {
        Args: { p_seed_thread_id: string; p_user_id: string }
        Returns: number
      }
      clear_thread_state: {
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
      find_auto_archive_candidates: {
        Args: { p_seed_thread_id: string; p_user_id: string }
        Returns: string[]
      }
      get_effective_role: {
        Args: { p_priority_id: string; p_user_id: string }
        Returns: string
      }
      has_priority_access: {
        Args: { priority_id: string; user_id: string }
        Returns: boolean
      }
      root_priority_id: { Args: { p_user_id: string }; Returns: string }
      sibling_contact_ids: { Args: { p_contact_id: string }; Returns: string[] }
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
          color: number | null
          config: Json | null
          created_at: string | null
          created_by: string | null
          default_contacts: string[] | null
          default_groups: string[] | null
          default_invite_emails: string[] | null
          early_notifications_enabled: boolean | null
          early_notifications_enabled_set: boolean | null
          global_path: unknown
          id: string | null
          inherit_members: boolean | null
          key: string | null
          notify_window: Json | null
          notify_window_set: boolean | null
          order: number | null
          path: unknown
          pomodoro: number | null
          respond_schedule_enabled: boolean | null
          respond_schedule_enabled_set: boolean | null
          respond_window: Json | null
          respond_window_set: boolean | null
          respond_within: Json | null
          respond_within_set: boolean | null
          role: string | null
          root: boolean | null
          see_within: Json | null
          see_within_set: boolean | null
          seq: unknown
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
          p_early_notifications_enabled?: boolean
          p_notify_window?: Json
          p_priority_id: string
          p_respond_schedule_enabled?: boolean
          p_respond_window?: Json
          p_respond_within?: Json
          p_see_within?: Json
          p_set_early_notifications_enabled?: boolean
          p_set_notify_window?: boolean
          p_set_respond_schedule_enabled?: boolean
          p_set_respond_window?: boolean
          p_set_respond_within?: boolean
          p_set_see_within?: boolean
          p_user_id: string
        }
        Returns: undefined
      }
      upsert_priority_block: {
        Args: { p_block: Json; user_id: string }
        Returns: {
          archived_at: string | null
          created_at: string | null
          created_by: string | null
          duration: string | null
          effective_at: string | null
          id: string | null
          order_value: number | null
          priority_id: string | null
          seq: unknown
          updated_at: string | null
          updated_by: number | null
          user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "priority_block"
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
          p_explicit?: boolean
          p_id: string
          p_occurrence_at?: string
          p_pomodoro: number
          p_pomodoro_at: string
          p_precedence: number
          p_priority_id: string
          p_schedule_id?: string
          p_source?: string
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
      upsert_thread_state: {
        Args: {
          p_active?: boolean
          p_at?: unknown
          p_bumped_at?: string
          p_importance?: number
          p_note_created_at?: string
          p_on?: unknown
          p_order?: number
          p_read_at?: string
          p_set_active?: boolean
          p_set_at?: boolean
          p_set_importance?: boolean
          p_set_on?: boolean
          p_set_order?: boolean
          p_set_read_at?: boolean
          p_set_task?: boolean
          p_set_to_read?: boolean
          p_set_urgent?: boolean
          p_task?: boolean
          p_thread_id: string
          p_to_read?: boolean
          p_urgent?: boolean
          user_id: string
        }
        Returns: Database["public"]["Tables"]["thread_state"]["Row"]
        SetofOptions: {
          from: "*"
          to: "thread_state"
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
      upsert_twist_instance: {
        Args: {
          p_account_label: string
          p_archived_at: string
          p_config: Json
          p_id: string
          p_name: string
          p_owner_id: string
          p_team_id: number
          p_twist_id: number
          user_id: string
        }
        Returns: Database["public"]["Tables"]["twist_instance"]["Row"]
        SetofOptions: {
          from: "*"
          to: "twist_instance"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_user_settings: {
        Args: {
          p_ai_enabled?: boolean
          p_enter_behavior: Database["public"]["Enums"]["enter_behavior"]
          p_onboarding_completed?: boolean
          p_tracking_paused_at?: string
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
      user_group_ids: { Args: { p_user_id: string }; Returns: string[] }
      user_has_thread_write_access: {
        Args: { p_thread_id: string; p_user_id: string }
        Returns: boolean
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
      email_frequency: ["daily", "weekly", "never"],
      enter_behavior: ["enter_newline", "enter_submits"],
      group_join_policy: ["member", "open", "admin"],
      group_type: ["public", "team", "private", "announce"],
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
      team_role: ["admin", "member"],
      twist_environment: ["personal", "private", "review", "public"],
    },
  },
  user: {
    Enums: {},
  },
} as const
