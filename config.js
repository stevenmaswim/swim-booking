// Fill these in from Supabase Dashboard > Project Settings > API
// The anon key is SAFE to expose publicly — security is enforced by
// Row Level Security in the database, not by hiding this key.
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";

const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
