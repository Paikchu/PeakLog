export async function fetchOwnedActualSets(admin, userId, linkedSetIds) {
  if (linkedSetIds.length === 0) return [];

  const { data, error } = await admin
    .from('exercise_sets')
    .select('*')
    .in('id', linkedSetIds)
    .eq('user_id', userId);
  if (error) throw error;
  return (data ?? []).filter((row) => row.user_id === userId);
}
