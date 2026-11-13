/** Both variants share an immutable upload version; older single objects stay readable. */
export function avatarObjectKeys(key: string): string[] {
  return key.endsWith("-thumbnail")
    ? [key, key.replace(/-thumbnail$/, "-original")]
    : [key];
}

/** Also removes leftovers from interrupted uploads or replacement cleanup. */
export async function deleteAccountAvatars(
  bucket: R2Bucket,
  userId: string,
): Promise<void> {
  const prefix = `user-avatars/${userId}/`;
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor });
    if (page.objects.length)
      await bucket.delete(page.objects.map((object) => object.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}
