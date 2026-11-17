# Crochet Heaven employment system setup

## What this branch adds
- A public Kenya careers page with vacancies from `public.job_postings`.
- Authenticated online applications stored in `public.job_applications`.
- HR-only vacancy publishing, application review, status changes, and direct candidate recording.
- Staff roles in `public.staff_memberships`, separate from independent marketplace sellers.
- Row-level security so applicants see only their own applications and active owner/admin/HR memberships can review applications.

## Bootstrap the founder account once
1. Deploy the branch to a preview environment and open Crochet Heaven.
2. Create your normal Crochet Heaven account and confirm your email if Supabase requires it.
3. In Supabase Dashboard > SQL Editor, replace the email below with the exact email used for your founder account and run this statement. Run it only as the project owner in SQL Editor; never expose database admin credentials in the browser.

```sql
insert into public.staff_memberships
  (user_id, role, employment_type, work_arrangement, country_code, status, job_title)
select
  id, 'owner', 'employee', 'either', 'KE', 'active', 'Founder'
from auth.users
where lower(email) = lower('YOUR_FOUNDER_EMAIL@example.com')
on conflict (user_id) do update
set role = 'owner',
    status = 'active',
    job_title = 'Founder',
    updated_at = now();
```

4. Sign out and sign back in, open Careers, and you should see the private Recruitment desk.
5. Post a vacancy, then test an applicant account separately. Test direct recruitment from the Recruitment desk.

If the SQL affects zero rows, confirm that the founder has completed account registration and that the email matches exactly.

## Important
- Staff memberships must be assigned only by a trusted project administrator. The public app deliberately has no endpoint that lets users promote themselves.
- Marketplace sellers remain independent sellers, not employees.
- This is a recruitment foundation, not a full payroll or HR compliance system. Before hiring, confirm written terms, applicable Kenyan wage rules, statutory deductions and employer registrations with a qualified Kenyan HR/payroll adviser.
- Do not collect national ID copies, bank details, health data or other sensitive documents in this first application form.
