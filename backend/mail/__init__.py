"""Consented customer email (#276, package named mail so it never shadows the stdlib email module): templates, deduplicated queue, SMTP sender.
Importing performs no network work and no module ever sends outside the
configured host; remote hosts need explicit owner activation."""
