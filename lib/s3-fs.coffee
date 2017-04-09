Bindable = require "bindable"
Model = require "model"

{pinvoke, startsWith, endsWith} = require "../util"

delimiter = "/"

status = (response) ->
  if response.status >= 200 && response.status < 300
    return response
  else
    throw response

json = (response) ->
  response.json()

blob = (response) ->
  response.blob()

uploadToS3 = (bucket, key, file, options={}) ->
  {cacheControl} = options

  cacheControl ?= 0

  pinvoke bucket, "putObject",
    Key: key
    ContentType: file.type
    Body: file
    CacheControl: "max-age=#{cacheControl}"

# TODO: May need to use getObject api when we switch to better privacy model
getFromS3 = (bucket, key) ->
  fetch("https://#{bucket.config.params.Bucket}.s3.amazonaws.com/#{key}")
  .then status
  .then blob

deleteFromS3 = (bucket, key) ->
  pinvoke bucket, "deleteObject",
    Key: key

list = (bucket, id, dir) ->
  unless startsWith dir, delimiter
    dir = "#{delimiter}#{dir}"

  unless endsWith dir, delimiter
    dir = "#{dir}#{delimiter}"

  prefix = "#{id}#{dir}"

  pinvoke bucket, "listObjects",
    Prefix: prefix
    Delimiter: delimiter
  .then (result) ->
    results = result.CommonPrefixes.map (p) ->
      FolderEntry p.Prefix, id, prefix
    .concat result.Contents.map (o) ->
      FileEntry o, id, prefix, bucket
    .map (entry) ->
      fetchMeta(entry, bucket)

    Promise.all results

module.exports = (id, bucket) ->

  localCache = {}

  notify = (eventType, path) ->
    (result) ->
      self.trigger eventType, path
      return result

  self = Model()
  .include Bindable
  .extend
    read: (path) ->
      unless startsWith path, delimiter
        path = delimiter + path

      key = "#{id}#{path}"

      cachedItem = localCache[key]
      if cachedItem
        if cachedItem instanceof Blob
          return Promise.resolve(cachedItem)
        else
          return Promise.reject(cachedItem)

      getFromS3(bucket, key)
      .catch (e) ->
        # Cache Not Founds too, since that's often what is slow
        localCache[key] = e
        throw e
      .then notify "read", path

    write: (path, blob) ->
      unless startsWith path, delimiter
        path = delimiter + path

      key = "#{id}#{path}"

      # Optimistically Cache
      localCache[key] = blob

      uploadToS3 bucket, key, blob
      .then notify "write", path

    delete: (path) ->
      unless startsWith path, delimiter
        path = delimiter + path

      key = "#{id}#{path}"

      localCache[key] = new Error "Not Found"

      deleteFromS3 bucket, key
      .then notify "delete", path

    list: (folderPath="/") ->
      list bucket, id, folderPath

fetchFileMeta = (fileEntry, bucket) ->
  pinvoke bucket, "headObject",
    Key: fileEntry.remotePath
  .then (result) ->
    fileEntry.type = result.ContentType

    fileEntry

fetchMeta = (entry, bucket) ->
  Promise.resolve()
  .then ->
    return entry if entry.folder

    fetchFileMeta entry, bucket

FolderEntry = (path, id, prefix) ->
  folder: true
  path: path.replace(id, "")
  relativePath: path.replace(prefix, "")
  remotePath: path

FileEntry = (object, id, prefix, bucket) ->
  path = object.Key

  entry =
    path: path.replace(id, "")
    relativePath: path.replace(prefix, "")
    remotePath: path
    size: object.Size

  entry.blob = BlobSham(entry, bucket)

  return entry

BlobSham = (entry, bucket) ->
  remotePath = entry.remotePath
  url = "https://#{bucket.config.params.Bucket}.s3.amazonaws.com/#{remotePath}"

  getURL: -> Promise.resolve(url)
  readAsText: ->
    getFromS3(bucket, remotePath)
    .then (blob) ->
      blob.readAsText()
