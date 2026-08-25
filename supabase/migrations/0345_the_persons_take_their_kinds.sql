-- 0345 — the corpus's persons take their kinds (ris_v19).
--
-- 757 persons assigned one of the owner's twelve closed subtypes;
-- 96 answered `none` and stay null — held unminted, not refused, per
-- 0342. Distribution: {'music_performer': 389, 'character': 195, 'none': 96, 'composer': 79, 'content_creator': 40, 'actor': 35, 'historical_figure': 5, 'director': 4, 'comedian': 3, 'athlete': 3, 'streamer': 2, 'author': 2}.
--
-- Updates key on (normalized_label, family='person'); a person this corpus
-- named that the dictionary does not hold updates nothing, and the count
-- below says how many landed rather than leaving the difference silent.

do $$
declare
  n integer := 0;
  touched integer;
begin
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = '444boy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = '88ds' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'a si' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'a yue yue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'a-mei chang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aastha gill' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'abao in tokyo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'addison rae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'adele' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'adrian thesen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aexgrant' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'afu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ahyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ai xing ren' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aidou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aimer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aimyon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aina the end' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aino jawo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'airplay' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aj michalka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'akayama yohhei' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'akhil' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alan gilbert' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alec benjamin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alexa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alexander borodin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ali tamposi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alisha chinai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'altan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'alysa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'amalee' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'amanda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'amber kuo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'amos' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'andrei mytnik' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'andris nelsons' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'andré previn' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'andy lau' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'andy nyman' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'angela chang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'anson seabra' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'anthony watts' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'antonio vivaldi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ariana grande' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'arijit singh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'asca' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'streamer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'asmongold' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'asuka okura' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'asuna' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'atarayo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'atif aslam' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'august stradal' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'augustin hadelich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'aurora' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ayase' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ayo97' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'b3rich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'babymonster ahyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bach' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'badshah' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'baocang shan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'batta' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bedřich smetana' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ben samama' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'benjamin francis leftwich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bernard haitink' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'beth fowler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'beyoncé' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bibi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bibi zhou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'billie eilish' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bingchuan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'binglue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bioinformagician' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bo yuan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'borneland' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'braska' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'breve' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bruno mars' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'bryan adams' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'c-low' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'call me karizma' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'historical_figure',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cao cao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'caralisa monteiro' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'carl wong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'carlos gardel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'carlos kleiber' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'caroline hjelt' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'casey lee williams' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chae won' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chaewon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chao chi lan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chappell roan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'charles o''connell' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'charli xcx' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'charlyne yi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen chusheng' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen duo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen lingtao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen mozhi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen xinzhe' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chen yiming' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chih siou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chiquita' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chiyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cho jeong eun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'choi ye-na' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'choi yena' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chrissy costanza' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'christina perri' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'christine fan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'christoph willibald gluck' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'chuu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cifer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'claude debussy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'claudio abbado' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cloud koh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cody tarpley' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'comedian',
         person_subtype_source = 'model_pass'
   where normalized_label = 'conan o''brien' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'conjr' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'constantin silvestri' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'corsak' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'courtney-mae briggs' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'csa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cvi.che' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cyndi wang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cynthia erivo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'cécile corbel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'd smoke' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'd-jin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'da vinci' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dame janet baker' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'comedian',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dang qianxinyi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'daniel barenboim' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'daniel caesar' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'daniel harding' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dao jiang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'darkyy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dasu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'david oistrakh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'david tao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'davido' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dawid podsiadło' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dayeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'author',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dean pitchford' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'delaney jane' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'della' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'deng fu-ru' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'deng jiudiao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'deng jiudiao jiahui' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'deng jiuxiaohuijia' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'deng xiajiuhuijia' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dhvani bhanushali' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'diane birch' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'diljit dosanjh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ding yuxi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'diplo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dj hasebe' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dj j.l.p' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dmitri shostakovich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'doja cat' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'don toliver' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dong jiji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dosi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'doudou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'dr. yishan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'eason chan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'econplusdal' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ed sheeran' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'edvard grieg' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'effie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ejae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'emanuel ax' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'emil gilels' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'emmanuel pahud' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'emptiso' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'eric chou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'etienne bazola' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'eun chae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'eunchae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'eve' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'evito' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'exy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fabel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'falcon punch' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fancywall' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'faye wong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'feli ferraro' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'felix' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'feng peilin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fish leong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fivestar' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'frank wildhorn' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'frankie kao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'franz liszt' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'françois-xavier roth' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fritz kreisler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'frédéric chopin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fu changpeng' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fu sichao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fujii kaze' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'fumiyo saki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'furong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'g-dragon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'g.e.m.' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gaeko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'athlete',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gatlin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ge dongqi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gen hoshino' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'historical_figure',
         person_subtype_source = 'model_pass'
   where normalized_label = 'georg fischer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gerhild romberger' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ghost' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'giacomo puccini' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'giselle' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'giuseppe verdi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'grabbitz' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'grace rolek' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'guanguan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gui bian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gumi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gustav holst' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gustav mahler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'gustavo dudamel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'györgy ligeti' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'h3r3' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hallie coggins' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'halsey' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hana blažíková' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hans zimmer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hanyuda takehiko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'harry styles' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'he lu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'he yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hebe tien' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'heo yoon-jin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'herbert von karajan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hevel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hikari' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hikaru utada' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hilary hahn' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'himiko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hiraidai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hiroyuki sawano' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hitori' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hitorie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hong eun-chae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hong eunchae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hoàng thùy linh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hsin kuang han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hsu kuang-han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'huang ling' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'huang shifu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hugh jackman' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'hugo kuang-han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'huh yunjin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'i''mdifficult' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'idina menzel' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'illjun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'imase' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'inryou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'isa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'itzhak perlman' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'iu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'j. lloyd' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'j.s. bach' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jackson shanks' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jaideep sahni' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jaira burns' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jake miller' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jane zhang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jang won-young' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jano lisboa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jason hahs' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jason yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jay chou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jaymes young' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jazzinuf' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jean sibelius' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jean-jacques kantorow' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jeff goldblum' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jeffree star' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jeffrey tate' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jellorio' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jenna boyd' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jennie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jeokbeom winter' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'athlete',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jeremy kushnier' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jerry c' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jess glynne' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jess lee' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jessi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jhove' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ji eum seo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ji yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jiang chi tongxue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jiang xiaonei' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jing yuge' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jj lin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jo yu-ri' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jo yuri' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'joanna wang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jodi milliner' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'joey yung' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'johann sebastian bach' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'historical_figure',
         person_subtype_source = 'model_pass'
   where normalized_label = 'johann wolfgang von goethe' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'johannes brahms' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'john eliot gardiner' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'john powell' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'john shanks' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'john williams' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'johnny klimek' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'joker xue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jolin tsai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jon bon jovi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jony j' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'josh starmer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'joshua bell' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jp saxe' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ju jingyi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'julia fischer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'julia michaels' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'julian prégardien' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'julie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jun ishikawa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jung ahyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'junko ohashi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'junpei fujita' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'justin bieber' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'justin lo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jvke' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jxsn' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'jérémie rhorer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kali uchis' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kang poong-gi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kanho yakushiji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kanisan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'karina' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kastra' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kate bush' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kate micucci' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kathleen battle' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kay tse' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kazuha' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kazumasa oda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kehlani' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kelly clarkson' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kelsea ballerini' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'comedian',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ken jeong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kenshi yonezu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kensuke ushio' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kenzie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kenzie smith' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'keshi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'khalil fong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kid princess' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim chae-won' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim chaewon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim da-yeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim dae-yeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim min-ju' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kim minju' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kimberley chen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kirill petrenko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kirito' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'koharanamu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'konnie aoki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kosuga taichi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kosuga tsuyoshi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'krasi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kreisler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'streamer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kripparrian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kristin chenoweth' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'krystal chan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kunaal vermaa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'kvi baba' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'laco' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lainey wilson' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lamar abrams' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lana del rey' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'landy wen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'laufey' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'laura shigihara' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lauren kaori' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'laurent korcia' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lea salonga' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lee ji-eun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lee seo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lee si-an' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'leehom wang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lei yuxin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'leonard bernstein' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'leonid kogan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lewis capaldi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'li ronghao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'li runqi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'li wei' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'li yue | xiang le le le' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lian qingkuang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lilas' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lilu xiu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lily-rose depp' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lin chia-ling' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lin mo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lin xing' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'line gøttsche' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lisa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'liu mang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'liu renyu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'liu sijian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'liu xiao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'liu yuning' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lizzy mcalpine' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'llano' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'loco' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'loki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'loote' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'loren allred' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'louice hellström' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'luciano pavarotti' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lucifer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lucile richardot' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lucy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ludwig van beethoven' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'luffy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'luka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lulleaux' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lydia kitto' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lyn' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'lyn lapid' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'm83' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ma yin yin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'madame vo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'madeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'madison beer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'madnap' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mahiru koda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mahler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'maize' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'malbeokji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mamoru miyano' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mao buyi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mariah the scientist' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mariya takeuchi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'marni nixon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'martha argerich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'marty' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'athlete',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mathias fritsche' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'matilda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'matryoshka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'maxim vengerov' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'maximilian hornung' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mc cheung tinfu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mc 張天賦' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'meng weilai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mi-jjang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'michael' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'michael mccorry rose' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'michelle williams' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'michelle yeoh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miguel harth-bedoya' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mika' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mika nakashima' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mikoto mukai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'milana chernyavska' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'milet' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'min kyung ah' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mina' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ming yue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'minji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'minju' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miwa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miyamoto koji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miyavi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miyuki nakajima' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'miyuna' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mizukami rimika' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mizuki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'morelearn 27' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mstislav rostropovich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'musa keys' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'mxmtoon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'historical_figure',
         person_subtype_source = 'model_pass'
   where normalized_label = 'na hoon-a' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'na yeong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nakka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nayeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nayina' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nerdie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'neuro traveler' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'neurosciq' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'neville marriner' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nezw' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'niccolò paganini' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nightly' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'niki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nikki flores' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nile rodgers' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ningning' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'no party for cao dong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'noah bendix-balgley' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'noah kahan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nori' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'noriyasu agemastu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'nulbarich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'oda asuka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'onion man' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'oorememberoo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ore no ayase' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'oscar dunbar' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pablo de sarasate' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pai gu jiao zhu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'panta.q' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pari' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'director',
         person_subtype_source = 'model_pass'
   where normalized_label = 'park chan-wook' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'patti smith' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'paul woolford' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pauline herr' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'director',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pei-yu hung' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'penny' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'penomeco' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'peter dinklage' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pewdiepie' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ph-1' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pharita' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'piggy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'porter robinson' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pritam' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pygmalion' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pyo eun-ji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pyo ye jin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'pyotr ilyich tchaikovsky' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'qi wei' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'qiang qiang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'qianying a' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'qing niao fei yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rachel kanner' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rachel podger' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rainie yang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'raj ranjodh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rami' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'raphaël pichon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'readon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'reagan gomez-preston' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'regina spektor' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rei' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rei yasuda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'reinhold heil' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'reinoud van mechelen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'reiwa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'reno wang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'richard tognetti' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ricky montgomery' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ritvik math' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'robert lloyd' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rockwell' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'roland pöntinen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ronny svendsen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'rora' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ruka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ryan jhun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ryan.b' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ryu jeong-han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ryu jung-han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sabine devieilhe' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sabrina carpenter' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'historical_figure',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sadhguru' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sadie killer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'saito neko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sam' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'samantha lam' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sammi cheng' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'santa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sarah christian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'satoshi yaginuma' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sawano hiroyuki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sawanohiroyuki[nzk]' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'saya hiyama' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'scott' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'se so neon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sennarin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'seo jeong-ah' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sergei rachmaninoff' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shallowend' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shan yi chun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shan yichun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sharon d. clarke' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shawn mendes' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sheena ringo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sheldon cooper' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shigenaga ryosuke' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shiina rin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shiina ringo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shin sakiura' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shiro' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shohey uemura' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shostakovich' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'shuang sheng' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sim eun-ji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'simon cockell' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'simon rattle' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sir john barbirolli' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sir neville marriner' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'snow' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sofia kay' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'softy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sojuwoon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'someshiit 山姆' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'song dongye' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'song nian yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sonny zero' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'soyou' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'starling8' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'stefanie sun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'stephen oremus' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'stephen schwartz' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'stevie wonder' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'stéphane degout' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'su bai shui xing la' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'suda kanna' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'suffa' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sufjan stevens' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sugar honey ice tea' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sui' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sullyoon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sun xuanyu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sunkis' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'support my big sister' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'supreme boi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sus' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'susanna kwan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sviatoslav richter' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'swink' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'sylvia mcnair' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'taeyeon' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'taichi mukai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tanaka yuko' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tangoz' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tanya chua' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tate mcrae' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'taylor swift' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tchaikovsky' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ted lo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tedi papavrami' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'teng fu-ju' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'teng fu-ru' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'teodor currentzis' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'teresa teng' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'the kid laroi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'the l' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'the weeknd' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tia ray' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tian mi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tobey maguire as spider-man' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'toko miura' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tolein schbert' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tolein xuebo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tom snow' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'director',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tom tykwer' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'trefor bazett' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'troye sivan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tyler, the creator' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'tzzzzz' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'u sung eun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'author',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ueda akinari' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'valentina melilla' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'vaundy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'verbal jint' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'visualsounds1' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'vitals' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'vivian chow' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'víkingur ólafsson' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wakin chau' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wan saiwen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang heye' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang linkai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang linyang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang lixin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang shasha' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang sisi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang xiaokun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang xiaowen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wang yino' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'weibird' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'winter' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wolfgang amadeus mozart' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'won' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wonhee' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wu bai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wu hai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wu hao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wu jingli' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wu xian' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'wynton marsalis' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xander.' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xiao ling' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xiao yiqing' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xiaole shirley liu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xin di' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xu chenglong' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xu liang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xu song' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'xuan xiao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yama' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yang jiarui' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yang yo-seob' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yasumu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yeji' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yena' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yin lin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yisa yu' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'content_creator',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yishan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yo yo honey singh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yoga lin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yoo jung-han' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yoon gong joo' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yosh' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'young' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'youngcaptain' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yu jiayun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yu zhen' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuan yexi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yui' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuinijiki' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yujin' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuko ando' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuko tanaka' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yumi matsutoya' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuqi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yushi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuttchaco' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'yuuri' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zach callison' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zelda' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zeus' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang dongni' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang qiang' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'composer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang siyun' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang xinyao' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang yi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'director',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhang yuan' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zhong qi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zico' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ziv zaifman' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zkaaai' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zou ru' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'zui xue' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'ólafur arnalds' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = 'øneheart' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'music_performer',
         person_subtype_source = 'model_pass'
   where normalized_label = 'øzi' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = '你的大表哥曲甲' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = '等一下就回家' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'character',
         person_subtype_source = 'model_pass'
   where normalized_label = '螺丝刀rosedoggy' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  update semantic_private.presumed_terms
     set person_subtype = 'actor',
         person_subtype_source = 'model_pass'
   where normalized_label = '許光漢' and family = 'person'
     and person_subtype is null;
  get diagnostics touched = row_count; n := n + touched;
  raise notice '0345: % of 757 subtype assignments landed', n;
  if 757 > 0 and n = 0 then
    raise exception
      '0345: assignments were emitted and none matched a dictionary row';
  end if;
end;
$$;

