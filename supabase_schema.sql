-- RUN THIS IN YOUR SUPABASE SQL EDITOR

-- 1. Create Tables

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT NOT NULL,
    name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('host', 'student')),
    student_id TEXT,
    avatar_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.classrooms (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    department TEXT,
    institution TEXT,
    semester TEXT,
    academic_year TEXT,
    host_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.classroom_members (
    classroom_id UUID REFERENCES public.classrooms(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    joined_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (classroom_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.resources (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    classroom_id UUID REFERENCES public.classrooms(id) ON DELETE CASCADE NOT NULL,
    uploaded_by UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    subject TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    file_path TEXT NOT NULL,
    file_size TEXT NOT NULL,
    file_type TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.resource_downloads (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    resource_id UUID REFERENCES public.resources(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    downloaded_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.announcements (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    classroom_id UUID REFERENCES public.classrooms(id) ON DELETE CASCADE NOT NULL,
    posted_by UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    priority TEXT DEFAULT 'Normal',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.assignments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    classroom_id UUID REFERENCES public.classrooms(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    subject TEXT NOT NULL,
    description TEXT,
    due_date TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.activity_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    classroom_id UUID REFERENCES public.classrooms(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    action TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);


-- 2. Setup Profile Creation Trigger (Fixes Signup Issue)
-- This automatically creates a profile when a user signs up.

create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, name, role, student_id)
  values (
    new.id,
    new.email,
    COALESCE(new.raw_user_meta_data->>'name', 'Unknown User'),
    COALESCE(new.raw_user_meta_data->>'role', 'student'),
    new.raw_user_meta_data->>'student_id'
  );
  return new;
end;
$$ language plpgsql security definer;

-- Trigger the function every time a user is created
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- 3. Enable Row Level Security (RLS)

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.classrooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.classroom_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resource_downloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;

-- 4. RLS Policies

-- Profiles: Users can read all profiles, but only update their own.
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert their own profile" ON public.profiles;
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);


-- Classrooms: Viewable by host or members.
DROP POLICY IF EXISTS "Classrooms viewable by members or host" ON public.classrooms;
CREATE POLICY "Classrooms viewable by members or host" ON public.classrooms FOR SELECT USING (
    host_id = auth.uid() OR 
    id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can insert classrooms" ON public.classrooms;
CREATE POLICY "Hosts can insert classrooms" ON public.classrooms FOR INSERT WITH CHECK (host_id = auth.uid());

DROP POLICY IF EXISTS "Hosts can update own classrooms" ON public.classrooms;
CREATE POLICY "Hosts can update own classrooms" ON public.classrooms FOR UPDATE USING (host_id = auth.uid());

DROP POLICY IF EXISTS "Hosts can delete own classrooms" ON public.classrooms;
CREATE POLICY "Hosts can delete own classrooms" ON public.classrooms FOR DELETE USING (host_id = auth.uid());


-- Classroom Members: SELECT is completely open to avoid recursion. Hosts manage inserts/deletes.
DROP POLICY IF EXISTS "Members viewable by class members/host" ON public.classroom_members;
DROP POLICY IF EXISTS "Members viewable by all authenticated" ON public.classroom_members;
CREATE POLICY "Members viewable by all authenticated" ON public.classroom_members FOR SELECT USING (true);

DROP POLICY IF EXISTS "Hosts can insert members" ON public.classroom_members;
CREATE POLICY "Hosts can insert members" ON public.classroom_members FOR INSERT WITH CHECK (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can update members" ON public.classroom_members;
CREATE POLICY "Hosts can update members" ON public.classroom_members FOR UPDATE USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can delete members" ON public.classroom_members;
CREATE POLICY "Hosts can delete members" ON public.classroom_members FOR DELETE USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);


-- Resources: Read by members/host. Insert by members/host. Edit/Delete by uploader OR Host.
DROP POLICY IF EXISTS "Resources viewable by class members" ON public.resources;
CREATE POLICY "Resources viewable by class members" ON public.resources FOR SELECT USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Members can insert resources" ON public.resources;
CREATE POLICY "Members can insert resources" ON public.resources FOR INSERT WITH CHECK (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Uploader or Host can update resources" ON public.resources;
CREATE POLICY "Uploader or Host can update resources" ON public.resources FOR UPDATE USING (
    uploaded_by = auth.uid() OR classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);

DROP POLICY IF EXISTS "Uploader or Host can delete resources" ON public.resources;
CREATE POLICY "Uploader or Host can delete resources" ON public.resources FOR DELETE USING (
    uploaded_by = auth.uid() OR classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);


-- Announcements: Viewable by members. Insert/Update/Delete by Host.
DROP POLICY IF EXISTS "Announcements viewable by members" ON public.announcements;
CREATE POLICY "Announcements viewable by members" ON public.announcements FOR SELECT USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can manage announcements" ON public.announcements;
CREATE POLICY "Hosts can manage announcements" ON public.announcements FOR ALL USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);


-- Assignments: Viewable by members. Insert/Update/Delete by Host.
DROP POLICY IF EXISTS "Assignments viewable by members" ON public.assignments;
CREATE POLICY "Assignments viewable by members" ON public.assignments FOR SELECT USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can manage assignments" ON public.assignments;
CREATE POLICY "Hosts can manage assignments" ON public.assignments FOR ALL USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);


-- Activity Logs: Viewable by members. Insert by members/host. Delete by host.
DROP POLICY IF EXISTS "Logs viewable by members" ON public.activity_logs;
CREATE POLICY "Logs viewable by members" ON public.activity_logs FOR SELECT USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Members can insert logs" ON public.activity_logs;
CREATE POLICY "Members can insert logs" ON public.activity_logs FOR INSERT WITH CHECK (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid()) OR 
    classroom_id IN (SELECT classroom_id FROM public.classroom_members WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Hosts can delete logs" ON public.activity_logs;
CREATE POLICY "Hosts can delete logs" ON public.activity_logs FOR DELETE USING (
    classroom_id IN (SELECT id FROM public.classrooms WHERE host_id = auth.uid())
);


-- Resource Downloads:
DROP POLICY IF EXISTS "Downloads trackable by members" ON public.resource_downloads;
CREATE POLICY "Downloads trackable by members" ON public.resource_downloads FOR ALL USING (
    user_id = auth.uid() OR
    resource_id IN (
        SELECT r.id FROM public.resources r 
        JOIN public.classrooms c ON r.classroom_id = c.id 
        WHERE c.host_id = auth.uid()
    )
);

-- 6. Enable Realtime
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'resources'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.resources;
    ALTER PUBLICATION supabase_realtime ADD TABLE public.announcements;
    ALTER PUBLICATION supabase_realtime ADD TABLE public.assignments;
    ALTER PUBLICATION supabase_realtime ADD TABLE public.classroom_members;
    ALTER PUBLICATION supabase_realtime ADD TABLE public.activity_logs;
    ALTER PUBLICATION supabase_realtime ADD TABLE public.classrooms;
  END IF;
END $$;

-- 7. Storage Bucket Policy (Must create bucket named 'resources' in Storage dashboard first)
-- If the bucket already exists, these policies secure it:
DROP POLICY IF EXISTS "Authenticated users can upload resources" ON storage.objects;
CREATE POLICY "Authenticated users can upload resources" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'resources');

DROP POLICY IF EXISTS "Authenticated users can select resources" ON storage.objects;
CREATE POLICY "Authenticated users can select resources" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'resources');

DROP POLICY IF EXISTS "Users can update their own resources" ON storage.objects;
CREATE POLICY "Users can update their own resources" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'resources' AND (auth.uid() = owner));

DROP POLICY IF EXISTS "Users can delete their own resources" ON storage.objects;
CREATE POLICY "Users can delete their own resources" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'resources' AND (auth.uid() = owner));
