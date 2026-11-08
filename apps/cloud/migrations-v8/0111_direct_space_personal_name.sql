-- A personal label never changes the other participant's profile or view.
ALTER TABLE direct_space_user_state ADD COLUMN personal_name TEXT;
