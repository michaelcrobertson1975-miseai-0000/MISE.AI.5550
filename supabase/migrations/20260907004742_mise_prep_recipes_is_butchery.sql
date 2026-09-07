-- Additive only. The Cook App distinguishes a fixed-batch recipe (Clam
-- Chowder: cook a recipe, hit a portion target) from a butchery/breakdown
-- item (Atlantic Salmon: no fixed target, weigh in and weigh out whatever
-- fish actually showed up). Sniffing this from batch_yield text is
-- unreliable (both recipes' text can contain the word "portions"), so this
-- is a real, explicit column instead.
alter table public.prep_recipes add column if not exists is_butchery boolean not null default false;
update public.prep_recipes set is_butchery = true where name ilike '%butcher%' or name ilike '%portion prep%';
comment on column public.prep_recipes.is_butchery is 'True for a breakdown/butchery item with no fixed batch yield (weigh-in/weigh-out flow) rather than a fixed-recipe batch (portion-count target flow).';