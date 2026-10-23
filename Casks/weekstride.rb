cask "weekstride" do
  version "0.8.1,67"
  sha256 "ea7f7ba2610d27126eaa15ac90d070260c86f50d3bda08d10df3fbfef06979d1"

  url "https://github.com/zhutong1998/weekstride/releases/download/v#{version.csv.first}/weekstride-#{version.csv.first}-#{version.csv.second}-macos-arm64.zip"
  name "WeekStride"
  name "周程"
  desc "Weekly task planner with local storage"
  homepage "https://github.com/zhutong1998/weekstride"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "WeekStride.app"
end
