cask "weekstride" do
  version "0.8.1,67"
  sha256 "725fc0ff8e097d59c34502cdb2d906b2637467b19c6dc054d7a6f2f589a4cb62"

  url "https://github.com/zhutong1998/weekstride/releases/download/v#{version.csv.first}/weekstride-#{version.csv.first}-#{version.csv.second}-macos-arm64.zip"
  name "WeekStride"
  name "周程"
  desc "Weekly task planner with local storage"
  homepage "https://github.com/zhutong1998/weekstride"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "WeekStride.app"
end
