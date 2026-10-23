-- Drop suspect.behaviouralindicators. Nothing in the app or the policies
-- uses it, weapons have their own table now, and physical/clothing
-- descriptions stay on suspect. Whatever was in the column is gone.

ALTER TABLE public.suspect DROP COLUMN behaviouralindicators;
