/* ==========================================================================
   Careers — the application form
   --------------------------------------------------------------------------
   The listing page needs none of this: its hover arrow is pure CSS and its
   links are plain anchors. This file exists only for /en-us/careers/apply/,
   which has no session to lean on — the site makes no auth call anywhere
   else — so it talks to Supabase's REST and Storage endpoints directly with
   the same publishable anon key AppConfig.swift ships, rather than pulling in
   a client library this is the only page that would use.

   The resume and the row are two independent writes, in that order: the
   upload first, the insert naming its path second. If the second never
   arrives the first is an orphaned object nobody's row names — acceptable,
   since nothing reads this bucket back except a human with the service key,
   and a lost upload costs nothing a retry does not fix.
   ========================================================================== */

(function () {
  'use strict';

  var SUPABASE_URL = 'https://fwnezkbesjoazlpaflbq.supabase.co';
  var SUPABASE_ANON_KEY = 'sb_publishable_rKIU-q6beAiLawLkjEiMYA_vZNmC2aT';
  var MAX_RESUME_BYTES = 10 * 1024 * 1024;

  var ROLES = {
    'android-engineer':            { title: 'Android Engineer',            department: 'engineering' },
    'ios-engineer':                { title: 'iOS Engineer',                department: 'engineering' },
    'backend-engineer':             { title: 'Backend Engineer',            department: 'engineering' },
    'machine-learning-engineer':   { title: 'Machine Learning Engineer',   department: 'engineering' },
    'brand-marketing':             { title: 'Brand Marketing',             department: 'marketing' },
    'art-designer':                { title: 'Art Designer',                department: 'marketing' }
  };

  function emptyToNull(v) {
    v = (v || '').trim();
    return v === '' ? null : v;
  }

  function looksLikeEmail(v) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
  }

  function randomUUID() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') {
      return window.crypto.randomUUID();
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0;
      var v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  function uploadResume(path, file) {
    return fetch(SUPABASE_URL + '/storage/v1/object/job-application-resumes/' + path, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': file.type || 'application/octet-stream'
      },
      body: file
    }).then(function (res) {
      if (!res.ok) throw new Error('resume upload failed: ' + res.status);
    });
  }

  function insertApplication(row) {
    return fetch(SUPABASE_URL + '/rest/v1/job_applications', {
      method: 'POST',
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal'
      },
      body: JSON.stringify(row)
    }).then(function (res) {
      if (!res.ok) throw new Error('application insert failed: ' + res.status);
    });
  }

  function initApplyPage() {
    var form = document.getElementById('applyForm');
    if (!form) return;

    var slug = new URLSearchParams(window.location.search).get('role') || '';
    var role = ROLES[slug];

    if (!role) {
      window.location.replace('/en-us/careers/');
      return;
    }

    document.title = role.title + ' — Join Written';
    document.getElementById('applyDept').textContent =
      role.department === 'engineering' ? 'Engineering' : 'Marketing';
    document.getElementById('applyTitle').textContent = role.title;
    document.getElementById('applyDoneTitle').textContent = role.title;
    if (role.department === 'engineering') {
      document.getElementById('githubField').hidden = false;
    }

    /* Pronoun pills: single-select, like the app's own single-choice rows —
       picking a second one replaces the first rather than adding to it.
       "Other" reveals a free-text field instead of forcing a fixed set. */
    var pronounGroup = document.getElementById('pronounGroup');
    var pronounOther = document.getElementById('pronounOther');
    var pronounValue = '';

    pronounGroup.addEventListener('click', function (e) {
      var btn = e.target.closest('.pill');
      if (!btn) return;
      var wasActive = btn.classList.contains('is-active');

      Array.prototype.forEach.call(pronounGroup.querySelectorAll('.pill'), function (p) {
        p.classList.remove('is-active');
        p.setAttribute('aria-pressed', 'false');
      });

      if (wasActive) {
        pronounValue = '';
        pronounOther.hidden = true;
        return;
      }

      btn.classList.add('is-active');
      btn.setAttribute('aria-pressed', 'true');

      if (btn.dataset.value === 'other') {
        pronounOther.hidden = false;
        pronounOther.focus();
        pronounValue = pronounOther.value;
      } else {
        pronounOther.hidden = true;
        pronounValue = btn.dataset.value;
      }
    });

    pronounOther.addEventListener('input', function () {
      pronounValue = pronounOther.value;
    });

    var errorEl = document.getElementById('applyError');
    var submitBtn = document.getElementById('applySubmit');

    function showError(msg) {
      errorEl.textContent = msg;
      errorEl.hidden = false;
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      errorEl.hidden = true;

      var fd = new FormData(form);
      var fullName = (fd.get('full_name') || '').toString().trim();
      var email = (fd.get('email') || '').toString().trim();
      var phone = (fd.get('phone') || '').toString().trim();
      var location = (fd.get('current_location') || '').toString().trim();
      var resumeFile = form.resume.files[0];

      if (!fullName || !email || !phone || !location) {
        showError('Please fill in every required field.');
        return;
      }
      if (!looksLikeEmail(email)) {
        showError('That email address does not look right.');
        return;
      }
      if (!resumeFile) {
        showError('Attach your resume or CV to continue.');
        return;
      }
      if (resumeFile.size > MAX_RESUME_BYTES) {
        showError('That file is larger than 10 MB — try a smaller export.');
        return;
      }

      var applicationId = randomUUID();
      var safeName = resumeFile.name.replace(/[^A-Za-z0-9.\-_]/g, '_');
      var objectPath = applicationId + '/' + safeName;

      submitBtn.disabled = true;
      submitBtn.textContent = 'Submitting…';

      uploadResume(objectPath, resumeFile)
        .then(function () {
          return insertApplication({
            id: applicationId,
            department: role.department,
            role_slug: slug,
            role_title: role.title,
            full_name: fullName,
            pronoun: emptyToNull(pronounValue),
            email: email,
            phone: phone,
            current_location: location,
            linkedin_url: emptyToNull(fd.get('linkedin_url')),
            github_url: emptyToNull(fd.get('github_url')),
            resume_object_path: objectPath
          });
        })
        .then(function () {
          form.hidden = true;
          document.getElementById('applyDone').hidden = false;
        })
        .catch(function () {
          submitBtn.disabled = false;
          submitBtn.textContent = 'Submit application';
          showError('Something went wrong sending your application — please try again, or email hello@written-stl.com directly.');
        });
    });
  }

  initApplyPage();
})();
