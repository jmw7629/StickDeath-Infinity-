-- =============================================================================
-- Seed Data for StickDeath Infinity
-- Run after migrations: supabase db seed
--
-- Includes:
--   • Default creator badges
--   • Default library sources (attribution data)
--   • Sample SFX library entries
--   • Sample library assets
--   • Default challenge
-- =============================================================================

-- ─────────────────────────────────────────────
-- Creator Badges
-- ─────────────────────────────────────────────
INSERT INTO public.creator_badges (id, code, label, icon_key, description, sort_order) VALUES
    (gen_random_uuid()::text, 'og',            'OG Creator',       'crown',     'One of the original StickDeath Infinity creators', 1),
    (gen_random_uuid()::text, 'top_creator',   'Top Creator',      'star',      'Recognized for exceptional animation work', 2),
    (gen_random_uuid()::text, 'rising_star',   'Rising Star',      'rocket',    'Rapidly growing creator with great potential', 3),
    (gen_random_uuid()::text, 'prolific',      'Prolific',         'fire',      'Published 50+ animations', 4),
    (gen_random_uuid()::text, 'community_hero','Community Hero',   'heart',     'Active community contributor and helper', 5),
    (gen_random_uuid()::text, 'challenge_champ','Challenge Champ', 'trophy',    'Won 3+ community challenges', 6),
    (gen_random_uuid()::text, 'beta_tester',   'Beta Tester',      'flask',     'Helped test StickDeath Infinity during beta', 7),
    (gen_random_uuid()::text, 'verified',      'Verified',         'check',     'Verified creator account', 8),
    (gen_random_uuid()::text, 'supporter',     'Supporter',        'gem',       'Supporting StickDeath Infinity with a paid plan', 9),
    (gen_random_uuid()::text, 'ai_pioneer',    'AI Pioneer',       'sparkles',  'Early adopter of AI animation tools', 10)
ON CONFLICT (code) DO NOTHING;


-- ─────────────────────────────────────────────
-- Library Sources (license attribution)
-- ─────────────────────────────────────────────
INSERT INTO public.library_sources (key, name, license_name, license_url, attribution_text) VALUES
    ('kenney',    'Kenney.nl',        'CC0 1.0',     'https://creativecommons.org/publicdomain/zero/1.0/',  'Assets by Kenney (kenney.nl) — CC0 Public Domain'),
    ('opengameart','OpenGameArt.org', 'Various',     'https://opengameart.org/content/faq#licenses',        'Assets from OpenGameArt.org — see individual asset licenses'),
    ('stickdeath','StickDeath Original','Proprietary','https://stickdeath.com/terms',                       'Original StickDeath Infinity assets — all rights reserved'),
    ('freesound', 'Freesound.org',    'Various',     'https://freesound.org/help/faq/#licenses',            'Sounds from Freesound.org — see individual sound licenses'),
    ('mixkit',    'Mixkit',           'Mixkit License','https://mixkit.co/license/',                        'Assets from Mixkit — free for commercial use')
ON CONFLICT (key) DO NOTHING;


-- ─────────────────────────────────────────────
-- Sample SFX Library Entries
-- Categories: impact, whoosh, ui, ambient, voice, music
-- ─────────────────────────────────────────────
INSERT INTO public.studio_sfx (name, tags, category, duration_ms, file_url, source_key, external_id, layer, intensity) VALUES
    -- Impact sounds
    ('Punch Hit Hard',       ARRAY['punch', 'hit', 'combat', 'impact'],       'impact',  320,  '/sfx/impact/punch-hard.mp3',         'kenney', 'impact_01', 'action', 'high'),
    ('Punch Hit Light',      ARRAY['punch', 'hit', 'combat', 'light'],        'impact',  210,  '/sfx/impact/punch-light.mp3',        'kenney', 'impact_02', 'action', 'low'),
    ('Kick Impact',          ARRAY['kick', 'hit', 'combat', 'impact'],        'impact',  280,  '/sfx/impact/kick-impact.mp3',        'kenney', 'impact_03', 'action', 'medium'),
    ('Body Slam',            ARRAY['slam', 'body', 'heavy', 'impact'],        'impact',  450,  '/sfx/impact/body-slam.mp3',          'kenney', 'impact_04', 'action', 'high'),
    ('Wall Hit',             ARRAY['wall', 'crash', 'impact', 'thud'],        'impact',  380,  '/sfx/impact/wall-hit.mp3',           'kenney', 'impact_05', 'action', 'medium'),
    ('Ground Pound',         ARRAY['ground', 'pound', 'heavy', 'impact'],     'impact',  520,  '/sfx/impact/ground-pound.mp3',       'kenney', 'impact_06', 'action', 'high'),
    ('Glass Shatter',        ARRAY['glass', 'shatter', 'break', 'impact'],    'impact',  680,  '/sfx/impact/glass-shatter.mp3',      'kenney', 'impact_07', 'action', 'high'),
    ('Metal Clang',          ARRAY['metal', 'clang', 'sword', 'impact'],      'impact',  350,  '/sfx/impact/metal-clang.mp3',        'kenney', 'impact_08', 'action', 'medium'),

    -- Whoosh sounds
    ('Sword Swing',          ARRAY['sword', 'swing', 'whoosh', 'weapon'],     'whoosh',  300,  '/sfx/whoosh/sword-swing.mp3',        'kenney', 'whoosh_01', 'action', 'medium'),
    ('Fast Whoosh',          ARRAY['fast', 'whoosh', 'movement', 'speed'],    'whoosh',  200,  '/sfx/whoosh/fast-whoosh.mp3',        'kenney', 'whoosh_02', 'action', 'low'),
    ('Heavy Whoosh',         ARRAY['heavy', 'whoosh', 'swing', 'power'],      'whoosh',  400,  '/sfx/whoosh/heavy-whoosh.mp3',       'kenney', 'whoosh_03', 'action', 'high'),
    ('Jump Whoosh',          ARRAY['jump', 'whoosh', 'movement', 'air'],      'whoosh',  250,  '/sfx/whoosh/jump-whoosh.mp3',        'kenney', 'whoosh_04', 'action', 'low'),
    ('Spin Attack',          ARRAY['spin', 'attack', 'whoosh', 'movement'],   'whoosh',  500,  '/sfx/whoosh/spin-attack.mp3',        'kenney', 'whoosh_05', 'action', 'high'),

    -- UI sounds
    ('Click',                ARRAY['click', 'ui', 'button', 'interface'],     'ui',      80,   '/sfx/ui/click.mp3',                 'kenney', 'ui_01',     'ui', NULL),
    ('Hover',                ARRAY['hover', 'ui', 'button', 'interface'],     'ui',      60,   '/sfx/ui/hover.mp3',                 'kenney', 'ui_02',     'ui', NULL),
    ('Success Chime',        ARRAY['success', 'chime', 'complete', 'win'],    'ui',      450,  '/sfx/ui/success-chime.mp3',         'kenney', 'ui_03',     'ui', NULL),
    ('Error Buzz',           ARRAY['error', 'buzz', 'fail', 'wrong'],         'ui',      300,  '/sfx/ui/error-buzz.mp3',            'kenney', 'ui_04',     'ui', NULL),
    ('Level Up',             ARRAY['levelup', 'upgrade', 'achievement'],      'ui',      800,  '/sfx/ui/level-up.mp3',              'kenney', 'ui_05',     'ui', NULL),
    ('Notification Ping',    ARRAY['notification', 'ping', 'alert', 'ui'],    'ui',      200,  '/sfx/ui/notification-ping.mp3',     'kenney', 'ui_06',     'ui', NULL),

    -- Ambient sounds
    ('Wind Loop',            ARRAY['wind', 'ambient', 'nature', 'loop'],      'ambient', 5000, '/sfx/ambient/wind-loop.mp3',        'kenney', 'amb_01',    'ambient', NULL),
    ('Rain Loop',            ARRAY['rain', 'ambient', 'nature', 'loop'],      'ambient', 5000, '/sfx/ambient/rain-loop.mp3',        'kenney', 'amb_02',    'ambient', NULL),
    ('City Background',      ARRAY['city', 'ambient', 'urban', 'loop'],       'ambient', 8000, '/sfx/ambient/city-bg.mp3',          'kenney', 'amb_03',    'ambient', NULL),
    ('Fire Crackling',       ARRAY['fire', 'crackling', 'ambient', 'loop'],   'ambient', 6000, '/sfx/ambient/fire-crackle.mp3',     'kenney', 'amb_04',    'ambient', NULL),
    ('Crowd Murmur',         ARRAY['crowd', 'murmur', 'people', 'loop'],      'ambient', 7000, '/sfx/ambient/crowd-murmur.mp3',     'kenney', 'amb_05',    'ambient', NULL),

    -- Voice / vocal effects
    ('Battle Cry',           ARRAY['battlecry', 'yell', 'voice', 'combat'],   'voice',   600,  '/sfx/voice/battle-cry.mp3',         'kenney', 'voice_01',  'action', 'high'),
    ('Pain Grunt',           ARRAY['pain', 'grunt', 'voice', 'hurt'],         'voice',   350,  '/sfx/voice/pain-grunt.mp3',         'kenney', 'voice_02',  'action', 'medium'),
    ('Death Scream',         ARRAY['death', 'scream', 'voice', 'ko'],         'voice',   800,  '/sfx/voice/death-scream.mp3',       'kenney', 'voice_03',  'action', 'high'),
    ('Laugh Evil',           ARRAY['laugh', 'evil', 'voice', 'villain'],      'voice',   1200, '/sfx/voice/evil-laugh.mp3',         'kenney', 'voice_04',  'action', 'medium'),

    -- Explosion / special
    ('Explosion Small',      ARRAY['explosion', 'boom', 'fire', 'small'],     'impact',  600,  '/sfx/impact/explosion-small.mp3',   'kenney', 'impact_09', 'action', 'high'),
    ('Explosion Large',      ARRAY['explosion', 'boom', 'fire', 'large'],     'impact',  1200, '/sfx/impact/explosion-large.mp3',   'kenney', 'impact_10', 'action', 'high'),
    ('Laser Shot',           ARRAY['laser', 'shot', 'scifi', 'weapon'],       'whoosh',  250,  '/sfx/whoosh/laser-shot.mp3',        'kenney', 'whoosh_06', 'action', 'medium'),
    ('Electric Zap',         ARRAY['electric', 'zap', 'shock', 'energy'],     'impact',  300,  '/sfx/impact/electric-zap.mp3',      'kenney', 'impact_11', 'action', 'medium')
ON CONFLICT DO NOTHING;


-- ─────────────────────────────────────────────
-- Sample Library Assets (stickmen, backgrounds, props)
-- ─────────────────────────────────────────────
INSERT INTO public.studio_library_assets (source_key, external_id, name, tags, category, file_url, preview_url) VALUES
    -- Stickmen
    ('stickdeath', 'stick_basic_01',     'Basic Stickman',        ARRAY['stickman', 'basic', 'character'],     'character', '/assets/library/characters/basic-stickman.svg', '/assets/library/characters/basic-stickman-thumb.png'),
    ('stickdeath', 'stick_ninja_01',     'Ninja Stickman',        ARRAY['stickman', 'ninja', 'character'],     'character', '/assets/library/characters/ninja-stickman.svg', '/assets/library/characters/ninja-stickman-thumb.png'),
    ('stickdeath', 'stick_warrior_01',   'Warrior Stickman',      ARRAY['stickman', 'warrior', 'character'],   'character', '/assets/library/characters/warrior-stickman.svg', '/assets/library/characters/warrior-stickman-thumb.png'),
    ('stickdeath', 'stick_mage_01',      'Mage Stickman',         ARRAY['stickman', 'mage', 'character'],      'character', '/assets/library/characters/mage-stickman.svg', '/assets/library/characters/mage-stickman-thumb.png'),
    ('stickdeath', 'stick_robot_01',     'Robot Stickman',        ARRAY['stickman', 'robot', 'scifi'],         'character', '/assets/library/characters/robot-stickman.svg', '/assets/library/characters/robot-stickman-thumb.png'),

    -- Weapons / Props
    ('stickdeath', 'prop_sword_01',      'Katana',                ARRAY['sword', 'katana', 'weapon', 'prop'],  'prop',      '/assets/library/props/katana.svg', '/assets/library/props/katana-thumb.png'),
    ('stickdeath', 'prop_gun_01',        'Pistol',                ARRAY['gun', 'pistol', 'weapon', 'prop'],    'prop',      '/assets/library/props/pistol.svg', '/assets/library/props/pistol-thumb.png'),
    ('stickdeath', 'prop_staff_01',      'Magic Staff',           ARRAY['staff', 'magic', 'weapon', 'prop'],   'prop',      '/assets/library/props/magic-staff.svg', '/assets/library/props/magic-staff-thumb.png'),
    ('stickdeath', 'prop_shield_01',     'Shield',                ARRAY['shield', 'defense', 'prop'],          'prop',      '/assets/library/props/shield.svg', '/assets/library/props/shield-thumb.png'),
    ('stickdeath', 'prop_nunchaku_01',   'Nunchaku',              ARRAY['nunchaku', 'weapon', 'martial'],      'prop',      '/assets/library/props/nunchaku.svg', '/assets/library/props/nunchaku-thumb.png'),

    -- Backgrounds
    ('stickdeath', 'bg_arena_01',        'Battle Arena',          ARRAY['arena', 'battle', 'background'],      'background','/assets/library/backgrounds/battle-arena.svg', '/assets/library/backgrounds/battle-arena-thumb.png'),
    ('stickdeath', 'bg_rooftop_01',      'City Rooftop',          ARRAY['rooftop', 'city', 'background'],      'background','/assets/library/backgrounds/city-rooftop.svg', '/assets/library/backgrounds/city-rooftop-thumb.png'),
    ('stickdeath', 'bg_forest_01',       'Dark Forest',           ARRAY['forest', 'dark', 'background'],       'background','/assets/library/backgrounds/dark-forest.svg', '/assets/library/backgrounds/dark-forest-thumb.png'),
    ('stickdeath', 'bg_dojo_01',         'Dojo Interior',         ARRAY['dojo', 'interior', 'background'],     'background','/assets/library/backgrounds/dojo-interior.svg', '/assets/library/backgrounds/dojo-interior-thumb.png'),
    ('stickdeath', 'bg_space_01',        'Space Station',         ARRAY['space', 'scifi', 'background'],       'background','/assets/library/backgrounds/space-station.svg', '/assets/library/backgrounds/space-station-thumb.png'),

    -- Effects
    ('stickdeath', 'fx_blood_01',        'Blood Splatter',        ARRAY['blood', 'splatter', 'effect'],        'effect',    '/assets/library/effects/blood-splatter.svg', '/assets/library/effects/blood-splatter-thumb.png'),
    ('stickdeath', 'fx_explosion_01',    'Explosion Flash',       ARRAY['explosion', 'flash', 'effect'],       'effect',    '/assets/library/effects/explosion-flash.svg', '/assets/library/effects/explosion-flash-thumb.png'),
    ('stickdeath', 'fx_lightning_01',    'Lightning Bolt',        ARRAY['lightning', 'bolt', 'effect'],         'effect',    '/assets/library/effects/lightning-bolt.svg', '/assets/library/effects/lightning-bolt-thumb.png'),
    ('stickdeath', 'fx_smoke_01',        'Smoke Puff',            ARRAY['smoke', 'puff', 'effect'],             'effect',    '/assets/library/effects/smoke-puff.svg', '/assets/library/effects/smoke-puff-thumb.png'),
    ('stickdeath', 'fx_speedlines_01',   'Speed Lines',           ARRAY['speed', 'lines', 'motion', 'effect'], 'effect',    '/assets/library/effects/speed-lines.svg', '/assets/library/effects/speed-lines-thumb.png')
ON CONFLICT DO NOTHING;


-- ─────────────────────────────────────────────
-- Default notification preferences text
-- (auto-created per user via trigger, but good to document defaults)
-- ─────────────────────────────────────────────
-- likes_enabled: true
-- comments_enabled: true
-- follows_enabled: true
-- admin_enabled: true
-- challenge_enabled: true
-- tips_enabled: true
