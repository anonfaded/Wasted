export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      account_actions: {
        Row: {
          account_id: string
          action_type: string
          created_at: string
          created_by: string | null
          expires_at: string
          id: string
          idempotency_key: string
        }
        Insert: {
          account_id: string
          action_type: string
          created_at?: string
          created_by?: string | null
          expires_at: string
          id?: string
          idempotency_key: string
        }
        Update: {
          account_id?: string
          action_type?: string
          created_at?: string
          created_by?: string | null
          expires_at?: string
          id?: string
          idempotency_key?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_actions_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      account_settings: {
        Row: {
          account_id: string
          initialized_at: string | null
          lock_timer_minutes: number
          revision: number
          updated_at: string
          updated_by: string | null
          usb_trigger_enabled: boolean
        }
        Insert: {
          account_id: string
          initialized_at?: string | null
          lock_timer_minutes?: number
          revision?: number
          updated_at?: string
          updated_by?: string | null
          usb_trigger_enabled?: boolean
        }
        Update: {
          account_id?: string
          initialized_at?: string | null
          lock_timer_minutes?: number
          revision?: number
          updated_at?: string
          updated_by?: string | null
          usb_trigger_enabled?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "account_settings_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: true
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      accounts: {
        Row: {
          created_at: string
          handle: string
          id: string
        }
        Insert: {
          created_at?: string
          handle: string
          id: string
        }
        Update: {
          created_at?: string
          handle?: string
          id?: string
        }
        Relationships: []
      }
      command_events: {
        Row: {
          account_id: string
          command_id: string
          created_at: string
          detail: string | null
          device_id: string
          event_type: string
          id: number
          result_code: string | null
        }
        Insert: {
          account_id: string
          command_id: string
          created_at?: string
          detail?: string | null
          device_id: string
          event_type: string
          id?: never
          result_code?: string | null
        }
        Update: {
          account_id?: string
          command_id?: string
          created_at?: string
          detail?: string | null
          device_id?: string
          event_type?: string
          id?: never
          result_code?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "command_events_command_fk"
            columns: ["command_id", "account_id", "device_id"]
            isOneToOne: false
            referencedRelation: "device_commands"
            referencedColumns: ["id", "account_id", "device_id"]
          },
        ]
      }
      device_commands: {
        Row: {
          account_id: string
          action_id: string
          command_type: string
          created_at: string
          device_id: string
          executing_at: string | null
          expires_at: string
          finished_at: string | null
          id: string
          received_at: string | null
          result_code: string | null
          state: string
        }
        Insert: {
          account_id: string
          action_id: string
          command_type: string
          created_at?: string
          device_id: string
          executing_at?: string | null
          expires_at: string
          finished_at?: string | null
          id?: string
          received_at?: string | null
          result_code?: string | null
          state?: string
        }
        Update: {
          account_id?: string
          action_id?: string
          command_type?: string
          created_at?: string
          device_id?: string
          executing_at?: string | null
          expires_at?: string
          finished_at?: string | null
          id?: string
          received_at?: string | null
          result_code?: string | null
          state?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_commands_action_fk"
            columns: ["action_id", "account_id"]
            isOneToOne: false
            referencedRelation: "account_actions"
            referencedColumns: ["id", "account_id"]
          },
          {
            foreignKeyName: "device_commands_device_fk"
            columns: ["device_id", "account_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id", "account_id"]
          },
        ]
      }
      device_status: {
        Row: {
          account_id: string
          actual_lock_timer_minutes: number
          actual_usb_trigger_enabled: boolean
          android_sdk: number
          app_version: string
          applied_settings_revision: number
          debug_mode: boolean
          device_id: string
          last_error_code: string | null
          last_error_message: string | null
          last_seen_at: string
          remote_enabled: boolean
          reset_supported: boolean
          timer_remaining_seconds: number
          timer_running: boolean
          timer_sampled_at: string
          updated_at: string
        }
        Insert: {
          account_id: string
          actual_lock_timer_minutes: number
          actual_usb_trigger_enabled: boolean
          android_sdk: number
          app_version: string
          applied_settings_revision?: number
          debug_mode: boolean
          device_id: string
          last_error_code?: string | null
          last_error_message?: string | null
          last_seen_at: string
          remote_enabled: boolean
          reset_supported: boolean
          timer_remaining_seconds: number
          timer_running: boolean
          timer_sampled_at: string
          updated_at: string
        }
        Update: {
          account_id?: string
          actual_lock_timer_minutes?: number
          actual_usb_trigger_enabled?: boolean
          android_sdk?: number
          app_version?: string
          applied_settings_revision?: number
          debug_mode?: boolean
          device_id?: string
          last_error_code?: string | null
          last_error_message?: string | null
          last_seen_at?: string
          remote_enabled?: boolean
          reset_supported?: boolean
          timer_remaining_seconds?: number
          timer_running?: boolean
          timer_sampled_at?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_status_device_account_fk"
            columns: ["device_id", "account_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id", "account_id"]
          },
        ]
      }
      devices: {
        Row: {
          account_id: string
          auth_user_id: string | null
          created_at: string
          enrolled_at: string
          id: string
          installation_id: string
          name: string
          revoked_at: string | null
          updated_at: string
        }
        Insert: {
          account_id: string
          auth_user_id?: string | null
          created_at?: string
          enrolled_at?: string
          id?: string
          installation_id: string
          name: string
          revoked_at?: string | null
          updated_at?: string
        }
        Update: {
          account_id?: string
          auth_user_id?: string | null
          created_at?: string
          enrolled_at?: string
          id?: string
          installation_id?: string
          name?: string
          revoked_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "devices_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      claim_device_enrollment: {
        Args: {
          p_device_name: string
          p_installation_id: string
          p_local_lock_timer_minutes: number
          p_local_usb_trigger_enabled: boolean
          p_token: string
        }
        Returns: {
          account_id: string
          auth_user_id: string | null
          created_at: string
          enrolled_at: string
          id: string
          installation_id: string
          name: string
          revoked_at: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "devices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_account_action: {
        Args: { p_action_type: string; p_idempotency_key: string }
        Returns: Json
      }
      create_device_enrollment: {
        Args: never
        Returns: {
          enrollment_id: string
          enrollment_token: string
          expires_at: string
        }[]
      }
      device_reconcile: {
        Args: {
          p_actual_lock_timer_minutes: number
          p_actual_usb_trigger_enabled: boolean
          p_android_sdk: number
          p_app_version: string
          p_applied_settings_revision: number
          p_debug_mode: boolean
          p_device_id: string
          p_last_error_code?: string
          p_last_error_message?: string
          p_remote_enabled: boolean
          p_reset_supported: boolean
          p_timer_remaining_seconds: number
          p_timer_running: boolean
        }
        Returns: Json
      }
      device_transition_command: {
        Args: {
          p_command_id: string
          p_detail?: string
          p_device_id: string
          p_expected_state: string
          p_new_state: string
          p_result_code?: string
        }
        Returns: {
          account_id: string
          action_id: string
          command_type: string
          created_at: string
          device_id: string
          executing_at: string | null
          expires_at: string
          finished_at: string | null
          id: string
          received_at: string | null
          result_code: string | null
          state: string
        }
        SetofOptions: {
          from: "*"
          to: "device_commands"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expire_account_commands: { Args: never; Returns: number }
      initialize_owner_account: {
        Args: { p_handle: string }
        Returns: {
          created_at: string
          handle: string
          id: string
        }
        SetofOptions: {
          from: "*"
          to: "accounts"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      rename_device: {
        Args: { p_device_id: string; p_name: string }
        Returns: {
          account_id: string
          auth_user_id: string | null
          created_at: string
          enrolled_at: string
          id: string
          installation_id: string
          name: string
          revoked_at: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "devices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      revoke_device: { Args: { p_device_id: string }; Returns: undefined }
      update_account_settings: {
        Args: {
          p_expected_revision: number
          p_lock_timer_minutes: number
          p_usb_trigger_enabled: boolean
        }
        Returns: {
          account_id: string
          initialized_at: string | null
          lock_timer_minutes: number
          revision: number
          updated_at: string
          updated_by: string | null
          usb_trigger_enabled: boolean
        }
        SetofOptions: {
          from: "*"
          to: "account_settings"
          isOneToOne: true
          isSetofReturn: false
        }
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
