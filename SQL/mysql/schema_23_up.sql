ALTER TABLE tracks ADD work integer;
ALTER TABLE tracks ADD subtitle blob;
ALTER TABLE tracks ADD grouping blob;
ALTER TABLE albums ADD subtitle blob;
ALTER TABLE albums ADD label blob;
CREATE INDEX tracksWorkIndex ON tracks (work);
CREATE TABLE works (
  id  integer PRIMARY KEY AUTOINCREMENT,
  composer integer,
  title blob,
  titlesort text,
  titlesearch text,
  FOREIGN KEY (`composer`) REFERENCES `contributors` (`id`) ON DELETE CASCADE
)
