import { createClient } from "@supabase/supabase-js";

// Filled in during Tahap 3 (database & auth wiring).
// Get these two values from your Supabase project: Settings -> API.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const supabase =
  supabaseUrl && supabaseAnonKey ? createClient(supabaseUrl, supabaseAnonKey) : null;
