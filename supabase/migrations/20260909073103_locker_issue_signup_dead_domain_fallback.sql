insert into locker_issues (title, description, area, status) values (
'signup function falls back to the dead old domain if MISE_MAIL_DOMAIN/MISE_OWNER_EMAIL secrets are unset',
'The signup edge function has hardcoded fallback values:
  const MAIL_DOMAIN = Deno.env.get(''MISE_MAIL_DOMAIN'') ?? ''in.miseai-0000.com'';
  const OWNER_EMAIL = Deno.env.get(''MISE_OWNER_EMAIL'') ?? ''michael@miseai-0000.com'';
miseai-0000.com is fully dead — deleted from Resend entirely, confirmed dead this session. If those two secrets are not set in Supabase when a real restaurant signs up, mise_onboard_client still creates the restaurant + intake address correctly (that part is already built, confirmed by reading the code), but the intake address handed to the restaurant will be on the dead domain and invoices sent there will vanish with no error.

signup already emails the working intake address to the restaurant automatically at signup, with an on-screen fallback if that email fails to send — so this is specifically about which domain gets baked into that address, not about the emailing mechanism itself.

STATUS: deferred on purpose since nobody is signing up yet. MUST be fixed (set MISE_MAIL_DOMAIN=miseai0010.com and MISE_OWNER_EMAIL to a real address on that domain, in Supabase Edge Function secrets) before any real customer goes through the signup form.',
'signup-flow',
'open'
);
