function slugifyTitle(title) {
  const raw = (title || '').toLowerCase();
  let short = raw.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (short.length > 30) short = short.substring(0, 30);
  if (!short) short = 'issue';
  return short;
}

function buildBranchName(issueNumber, title) {
  return `issue-${issueNumber}-${slugifyTitle(title)}`;
}

function versionBumpFromType(typeLabel) {
  if (typeLabel === 'feature') return 'major';
  if (typeLabel === 'bug') return 'minor';
  return 'none';
}

module.exports = {
  slugifyTitle,
  buildBranchName,
  versionBumpFromType,
};
