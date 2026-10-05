-- =====================================================================
-- Argus Shield: remove suspect.behaviouralindicators
--
-- Not used by the app or any policy. Weapons now have their own table
-- (weapondetail), and physical/clothing descriptions stay on suspect.
-- Any text already stored in this column is deleted.
-- =====================================================================

ALTER TABLE public.suspect DROP COLUMN behaviouralindicators;
