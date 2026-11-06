-- Lets a player's corrected shot results reach their backup.
--
-- shot_records was insert-only, so a make corrected to a miss (or a flagged
-- call fixed in the summary) stayed wrong in the cloud, and a restore
-- brought the wrong result back. After applying this, set
-- HoopTrack.Backend.shotRowsUpdatable = true in Constants.swift.

create policy "shot_records_update_own"
  on public.shot_records
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
