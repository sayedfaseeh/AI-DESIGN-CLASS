-- The submissions bucket already enforces file_size_limit (20MB) and
-- allowed_mime_types (png/jpeg/pdf) at the bucket level -- that part of the
-- original concern was already handled by Supabase Storage itself.
-- What was NOT enforced: the upload policy accepted literally any object
-- name, so anon could write arbitrary paths into the bucket unrelated to any
-- real student/quest. Tighten it to the {student_id}_{quest_id}_{timestamp}_{random}.{ext}
-- naming convention the client already uses in dashboard.html, as a
-- hygiene/defense-in-depth constraint (not a substitute for real auth).

drop policy if exists anon_upload_submissions on storage.objects;

create policy anon_upload_submissions
on storage.objects
for insert
to anon
with check (
  bucket_id = 'submissions'
  and name ~ '^[0-9]+_[A-Za-z0-9._-]+_[0-9]+_[A-Za-z0-9]+\.[A-Za-z0-9]+$'
);
